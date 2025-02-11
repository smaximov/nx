defmodule EXLA.Defn.Lock do
  @moduledoc false

  use GenServer
  require Logger

  @name __MODULE__
  @timeout :infinity

  @doc """
  Locks the given `key`.

  It will wait until the key becomes available.
  """
  # TODO: Once we support multiple devices, what happens if we are trying
  # to run on a device and the Nx.LazyContainer operations happen in another
  # one? Perhaps we should track pid => device and force all operations on
  # a certain device?
  def lock(key) do
    GenServer.call(@name, {:lock, key}, @timeout)
  end

  @doc """
  Transfers the lock to a new process.
  """
  def transfer(ref, prepare, pid)
      when is_reference(ref) and is_function(prepare, 0) and is_pid(pid) do
    GenServer.call(@name, {:transfer, ref, prepare, pid}, @timeout)
  end

  @doc """
  Registers what happens when the current lock is unlocked.

  The `prepare` is executed and then the new `to_unlock` is registered.
  """
  def on_unlock(ref, prepare, to_unlock)
      when is_reference(ref) and
             is_function(prepare, 0) and is_function(to_unlock, 0) do
    GenServer.call(@name, {:on_unlock, ref, prepare, to_unlock}, @timeout)
  end

  @doc """
  Unlocks the given `ref`.

  It will execute the registered `to_unlock` callback, if any.
  """
  def unlock(:nested_lock) do
    :ok
  end

  def unlock(ref) when is_reference(ref) do
    GenServer.call(@name, {:unlock, ref}, @timeout)
  end

  ## Callbacks

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, {%{}, %{}}}
  end

  @impl true
  def handle_call({:lock, key}, {pid, _} = from, {refs, devices}) do
    {refs, devices} =
      get_and_update_in(devices[key], fn
        # If this PID already has a lock, we allow it to go ahead using a :nested_lock.
        # The :nested_lock can only be unlocked, never transferred or customized.
        {{_to_unlock, ^pid}, _queue} = device ->
          GenServer.reply(from, :nested_lock)
          {refs, device}

        device ->
          device
          |> enqueue(from)
          |> dequeue_if_possible(key, refs)
      end)

    {:noreply, {refs, devices}}
  end

  def handle_call({:unlock, ref}, _from, {refs, devices}) do
    _ = Process.demonitor(ref, [:flush])
    {:reply, :ok, unlock(ref, refs, devices)}
  end

  def handle_call({:transfer, ref, prepare, pid}, _from, {refs, devices}) do
    {key, refs} = Map.pop!(refs, ref)
    _ = Process.demonitor(ref, [:flush])
    _ = prepare.()
    ref = Process.monitor(pid)

    devices =
      update_in(devices[key], fn {{to_unlock, _pid}, queue} -> {{to_unlock, pid}, queue} end)

    {:reply, ref, {Map.put(refs, ref, key), devices}}
  end

  def handle_call({:on_unlock, ref, prepare, to_unlock}, _from, {refs, devices}) do
    key = Map.fetch!(refs, ref)
    _ = prepare.()

    devices =
      update_in(devices[key], fn {{_to_unlock, pid}, queue} -> {{to_unlock, pid}, queue} end)

    {:reply, ref, {refs, devices}}
  end

  @impl true
  def handle_info({:DOWN, ref, _, _, _}, {refs, devices}) do
    {:noreply, unlock(ref, refs, devices)}
  end

  defp enqueue(nil, entry), do: enqueue({:unlocked, :queue.new()}, entry)
  defp enqueue({state, queue}, entry), do: {state, :queue.in(entry, queue)}

  defp unlock(ref, refs, devices) do
    case Map.pop(refs, ref, nil) do
      {nil, refs} ->
        {refs, devices}

      {key, refs} ->
        get_and_update_in(devices[key], fn {{to_unlock, _pid}, queue} ->
          case run_to_unlock(key, to_unlock) do
            {:transfer, new} when is_pid(new) ->
              ref = Process.monitor(new)
              {Map.put(refs, ref, key), {{fn -> :unlock end, new}, queue}}

            :unlock ->
              dequeue_if_possible({:unlocked, queue}, key, refs)
          end
        end)
    end
  end

  defp run_to_unlock(key, to_unlock) do
    to_unlock.()
  rescue
    exception ->
      Logger.error(
        "Unlocking #{inspect(key)} with #{inspect(to_unlock)} failed. " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :unlock
  end

  defp dequeue_if_possible({:unlocked, queue}, key, refs) do
    case :queue.out(queue) do
      {{:value, {pid, _} = from}, queue} ->
        ref = Process.monitor(pid)
        GenServer.reply(from, ref)
        {Map.put(refs, ref, key), {{fn -> :unlock end, pid}, queue}}

      {:empty, queue} ->
        {refs, {:unlocked, queue}}
    end
  end

  defp dequeue_if_possible({to_unlock_pid, queue}, _key, refs) do
    {refs, {to_unlock_pid, queue}}
  end
end
