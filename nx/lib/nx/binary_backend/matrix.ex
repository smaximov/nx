defmodule Nx.BinaryBackend.Matrix do
  @moduledoc false
  use Complex.Kernel
  import Kernel, except: [abs: 1]
  import Complex, only: [abs: 1]

  import Nx.Shared

  def ts(a_data, a_type, a_shape, b_data, b_type, b_shape, output_type, input_opts) do
    transform_a = input_opts[:transform_a]
    lower_input = input_opts[:lower]

    # if transform_a != none, the upper will become lower and vice-versa
    lower = transform_a == :none == lower_input

    opts = %{
      lower: lower,
      left_side: input_opts[:left_side]
    }

    a_matrix =
      a_data
      |> binary_to_matrix(a_type, a_shape)
      |> ts_transform_a(transform_a)
      |> ts_handle_opts(opts, :a)

    b_matrix_or_vec =
      case b_shape do
        {_rows, _cols} ->
          b_data |> binary_to_matrix(b_type, b_shape) |> ts_handle_opts(opts, :b)

        {_rows} ->
          b_data |> binary_to_vector(b_type) |> ts_handle_opts(opts, :b)
      end

    result =
      a_matrix
      |> do_ts(b_matrix_or_vec, b_shape)
      |> ts_handle_opts(opts, :result)

    matrix_to_binary(result, output_type)
  end

  # For ts_handle_opts/3, we need some theoretical proofs:

  # When lower: false, we need the following procedure
  # for reusing the lower_triangular engine:
  #
  # First, we need to reverse both rows and columns
  # so we can turn an upper-triangular matrix
  # into a lower-triangular one.
  # The result will also be reversed in this case.
  #
  # Proof:
  # For a result [x1, x2, x3.., xn] and a row [a1, a2, a4, ..., an]
  # we have the corresponding b = a1 * x1 + a2 * x2 + a3 * x3 + ...+ an * xn
  # Since the addition of a_i * x_i is commutative, by reversing the columns
  # of a, the yielded x will be reversed.
  # Furthermore, if we reverse the rows of a, we need to reverse the rows of b
  # so each row is kept together with it's corresponding result.
  #
  # For example, the system:
  # A = [[a b c], [0 d e], [0 0 f]]
  # b = [b1, b2, b3, b4]
  # which yields x = [x1, x2, x3, x4]
  # is therefore equivalent to:
  # A = [[f 0 0], [e d 0], [c b a]]
  # b = [b4, b3, b2, b1]
  # which yields [x4, x3, x2, x1]

  # For handling left_side: false
  # Let's notate the system matrix as L when it's a lower triangular matrix
  # and U when it's upper triangular
  #
  # To solve X.L = B, we can then transpose both sides:
  # transpose(X.L) = transpose(L).X_t = U.X_t = b_t
  # This equation, in turn, has the same shape (U.X = B) as the one we can solve through
  # applying `ts_handle_lower_opt` properly, which would yield X_t.
  # Transposing the result suffices for yielding the final result.

  defp ts_handle_opts(
         matrix,
         %{lower: true, left_side: true},
         _matrix_type
       ) do
    # Base case (lower: true, left_side: true)
    matrix
  end

  defp ts_handle_opts(
         matrix,
         %{lower: false, left_side: true},
         matrix_type
       ) do
    # lower: false, left_side: true
    # We need to follow the row-col reversing procedure
    case matrix_type do
      :a ->
        matrix
        |> Enum.map(&Enum.reverse/1)
        |> Enum.reverse()

      _ ->
        Enum.reverse(matrix)
    end
  end

  defp ts_handle_opts(
         [row_or_elem | _] = matrix,
         %{lower: lower, left_side: false},
         matrix_type
       ) do
    # left_side: false
    # transpose both sides of the equation (yielding X_t as the result)
    # We need to treat the transposed result as equivalent to lower: not lower, left_side: true,
    # (not lower) because the triangular matrix is transposed

    new_opts = %{lower: not lower, transform_a: :none, left_side: true}

    case matrix_type do
      :a ->
        matrix
        |> transpose_matrix()
        |> ts_handle_opts(new_opts, :a)

      :b when is_list(row_or_elem) ->
        matrix
        |> transpose_matrix()
        |> ts_handle_opts(new_opts, :b)

      :b ->
        ts_handle_opts(matrix, new_opts, :b)

      :result when is_list(row_or_elem) and lower ->
        matrix
        |> Enum.reverse()
        |> transpose_matrix()

      :result when is_list(row_or_elem) and not lower ->
        transpose_matrix(matrix)

      :result when lower ->
        Enum.reverse(matrix)

      :result when not lower ->
        matrix
    end
  end

  defp ts_transform_a(matrix, :transpose), do: transpose_matrix(matrix)
  defp ts_transform_a(matrix, _), do: matrix

  defp do_ts(a_matrix, b_matrix, {rows, cols}) do
    1..min(rows, cols)//1
    |> Enum.map(fn b_col ->
      b_vector = get_matrix_column(b_matrix, b_col - 1)

      do_ts(a_matrix, b_vector, 0, [])
    end)
    |> transpose_matrix()
  end

  defp do_ts(a_matrix, b_vector, {_}) do
    do_ts(a_matrix, b_vector, 0, [])
  end

  defp do_ts([row | rows], [b | bs], idx, acc) do
    value = Enum.fetch!(row, idx)

    if Complex.abs(value) == 0 do
      raise ArgumentError, "can't solve for singular matrix"
    end

    y = (b - dot_matrix(row, acc)) / value
    do_ts(rows, bs, idx + 1, acc ++ [y])
  end

  defp do_ts([], [], _idx, acc), do: acc

  def qr(input_data, input_type, input_shape, output_type, m, k, n, opts) do
    mode = opts[:mode]
    eps = opts[:eps]

    {q_matrix, r_matrix} =
      input_data
      |> binary_to_matrix(input_type, input_shape)
      |> qr_decomposition(m, n, eps)

    {q_matrix, r_matrix} =
      if mode == :reduced and m - k > 0 do
        # Remove unnecessary columns (rows) from the matrix Q (R)
        q_matrix = get_matrix_columns(q_matrix, 0..(k - 1))

        r_matrix = Enum.drop(r_matrix, k - m)

        {q_matrix, r_matrix}
      else
        {q_matrix, r_matrix}
      end

    {matrix_to_binary(q_matrix, output_type), matrix_to_binary(r_matrix, output_type)}
  end

  defp qr_decomposition(matrix, m, n, eps) when m >= n do
    # QR decomposition is performed by using Householder transform

    max_i = if m == n, do: n - 2, else: n - 1

    {q_matrix, r_matrix} =
      for i <- 0..max_i, reduce: {nil, matrix} do
        {q, r} ->
          h =
            r
            |> slice_matrix([i, i], [m - i, 1])
            |> householder_reflector(m, eps)

          # If we haven't allocated Q yet, let Q = H1
          # TODO: Resolve inconsistent with the Householder reflector.
          # cf. https://github.com/elixir-nx/nx/pull/933#discussion_r982772063
          q =
            if is_nil(q) do
              h
            else
              dot_matrix_real(q, h)
            end

          r = dot_matrix_real(h, r)
          {q, r}
      end

    {approximate_zeros(q_matrix, eps), approximate_zeros(r_matrix, eps)}
  end

  defp qr_decomposition(_, _, _, _) do
    raise ArgumentError, "tensor must have at least as many rows as columns"
  end

  def cholesky(data, {_, type_size} = type, {n, n} = shape, output_type) do
    matrix = binary_to_matrix(data, type, shape)

    # From wikipedia (https://en.wikipedia.org/wiki/Cholesky_decomposition#The_Cholesky%E2%80%93Banachiewicz_and_Cholesky%E2%80%93Crout_algorithms)
    # adapted to 0-indexing
    # Ljj := sqrt(Ajj - sum(k=0..j-1)[Complex.abs_squared(Ljk)])
    # Lij := 1/Ljj * (Aij - sum(k=0..j-1)[Lik * Complex.conjugate(Ljk)])

    zeros_size = n * n * type_size
    zeros = binary_to_matrix(<<0::size(zeros_size)>>, type, shape)

    # check if matrix is hermitian
    eps = 1.0e-10

    for i <- 0..(n - 1) do
      row = matrix |> get_matrix_rows([i]) |> List.flatten()
      col = matrix |> get_matrix_columns([i]) |> List.flatten()

      Enum.zip_with(row, col, fn a_ij, a_ji ->
        re_ij = Complex.real(a_ij)
        im_ij = Complex.imag(a_ij)

        re_ji = Complex.real(a_ji)
        im_ji = Complex.imag(a_ji)

        # Conj(a + bi) = a - bi

        if abs(re_ij - re_ji) > eps and not (re_ij == :nan and re_ji == :nan) do
          raise_not_hermitian()
        end

        case {im_ij, im_ji} do
          {:infinity, :neg_infinity} ->
            :ok

          {:neg_infinity, :infinity} ->
            :ok

          {:nan, :nan} ->
            :ok

          {x, y} ->
            if Complex.abs(x + y) > eps do
              raise_not_hermitian()
            end
        end
      end)
    end

    l =
      for i <- 0..(n - 1), j <- 0..i, i >= j, reduce: zeros do
        l ->
          [a_ij] = get_matrix_elements(matrix, [[i, j]])

          k_len = max(j, 0)
          slice_i = slice_matrix(l, [i, 0], [1, k_len])
          slice_j = slice_matrix(l, [j, 0], [1, k_len])

          sum =
            slice_i
            |> Enum.zip_with(slice_j, fn l_ik, l_jk -> l_ik * Complex.conjugate(l_jk) end)
            |> Enum.reduce(0, &+/2)

          l_ij =
            if i == j do
              Complex.sqrt(a_ij - sum)
            else
              [l_jj] = get_matrix_elements(l, [[j, j]])

              (a_ij - sum) / l_jj
            end

          replace_matrix_element(l, i, j, l_ij)
      end

    matrix_to_binary(l, output_type)
  end

  defp raise_not_hermitian do
    raise ArgumentError,
          "matrix must be hermitian, a matrix is hermitian iff X = adjoint(X)"
  end

  def eigh(input_data, input_type, {n, n} = input_shape, output_type, opts) do
    # The input Hermitian matrix A reduced to Hessenberg matrix H by Householder transform.
    # Then, by using QR iteration it converges to AQ = QΛ,
    # where Λ is the diagonal matrix of eigenvalues and the columns of Q are the eigenvectors.

    eps = opts[:eps]
    max_iter = opts[:max_iter]

    # Validate that the input is a Hermitian matrix using the relation A^* = A.
    a = binary_to_matrix(input_data, input_type, input_shape)

    is_hermitian =
      a
      |> transpose_matrix()
      |> Enum.map(fn a_row -> Enum.map(a_row, &Complex.conjugate(&1)) end)
      |> is_approximately_same?(a, eps)

    unless is_hermitian do
      raise_not_hermitian()
    end

    # Hessenberg decomposition
    {h, q_h} = hessenberg_decomposition(a, n, eps)

    # QR iteration for eigenvalues and eigenvectors
    {eigenvals_diag, eigenvecs} =
      Enum.reduce_while(1..max_iter, {h, q_h}, fn _, {a_old, q_old} ->
        # QR decomposition
        {q_now, r_now} = qr_decomposition(a_old, n, n, eps)

        # Update matrix A, Q
        a_new = dot_matrix_real(r_now, q_now)
        q_new = dot_matrix_real(q_old, q_now)

        if is_approximately_same?(q_old, q_new, eps) do
          {:halt, {a_new, q_new}}
        else
          {:cont, {a_new, q_new}}
        end
      end)

    # Obtain the eigenvalues, which are the diagonal elements
    indices_diag = for idx <- 0..(n - 1), do: [idx, idx]
    eigenvals = get_matrix_elements(eigenvals_diag, indices_diag)

    # In general, the eigenvalues of a Hermitian matrix are real numbers
    eigenvals_real = eigenvals |> Enum.map(&Complex.real(&1))

    # Reduce the elements smaller than eps to zero
    {eigenvals_real |> approximate_zeros(eps) |> matrix_to_binary(output_type),
     eigenvecs |> approximate_zeros(eps) |> matrix_to_binary(output_type)}
  end

  defp hessenberg_decomposition(matrix, n, eps) do
    # Hessenberg decomposition is performed by using Householder transform
    {hess_matrix, q_matrix} =
      for i <- 0..(n - 2), reduce: {matrix, nil} do
        {hess, q} ->
          h =
            hess
            |> slice_matrix([i + 1, i], [n - i - 1, 1])
            |> householder_reflector(n, eps)

          # If we haven't allocated Q yet, let Q = H1
          # TODO: Resolve inconsistent with the Householder reflector.
          # cf. https://github.com/elixir-nx/nx/pull/933#discussion_r982772063
          q =
            if is_nil(q) do
              h
            else
              dot_matrix_real(q, h)
            end

          # Hessenberg matrix H updating
          h_adj = adjoint_matrix(h)

          hess =
            h
            |> dot_matrix_real(hess)
            |> dot_matrix_real(h_adj)

          {hess, q}
      end

    {approximate_zeros(hess_matrix, eps), approximate_zeros(q_matrix, eps)}
  end

  defp is_approximately_same?(a, b, eps) do
    # Determine if matrices `a` and `b` are equal in the range of eps
    a
    |> Enum.zip(b)
    |> Enum.all?(fn {a_row, b_row} ->
      a_row
      |> Enum.zip(b_row)
      |> Enum.all?(fn
        {a_elem, b_elem} ->
          abs_diff = Complex.abs(a_elem - b_elem)

          abs_diff == :nan or abs_diff <= eps
      end)
    end)
  end

  def lu(input_data, input_type, {n, n} = input_shape, p_type, l_type, u_type, opts) do
    a = binary_to_matrix(input_data, input_type, input_shape)
    eps = opts[:eps]

    {p, a_prime} = lu_validate_and_pivot(a, n)

    # We'll work with linear indices because of the way each matrix
    # needs to be updated/accessed
    zeros_matrix = List.duplicate(List.duplicate(0, n), n)

    {l, u} =
      for j <- 0..(n - 1), reduce: {zeros_matrix, zeros_matrix} do
        {l, u} ->
          l = replace_matrix_element(l, j, j, 1.0)

          u =
            for i <- 0..j, reduce: u do
              u ->
                u_slice = slice_matrix(u, [0, j], [i, 1])
                l_slice = slice_matrix(l, [i, 0], [1, i])
                sum = dot_matrix(u_slice, l_slice)
                [a_ij] = get_matrix_elements(a_prime, [[i, j]])

                value = a_ij - sum

                if abs(value) < eps do
                  replace_matrix_element(u, i, j, 0)
                else
                  replace_matrix_element(u, i, j, value)
                end
            end

          l =
            for i <- j..(n - 1), i != j, reduce: l do
              l ->
                u_slice = slice_matrix(u, [0, j], [i, 1])
                l_slice = slice_matrix(l, [i, 0], [1, i])
                sum = dot_matrix(u_slice, l_slice)

                [a_ij] = get_matrix_elements(a_prime, [[i, j]])
                [u_jj] = get_matrix_elements(u, [[j, j]])

                value = (a_ij - sum) / u_jj

                if abs(value) < eps do
                  replace_matrix_element(l, i, j, 0)
                else
                  replace_matrix_element(l, i, j, value)
                end
            end

          {l, u}
      end

    # Transpose because since P is orthogonal, inv(P) = tranpose(P)
    # and we want to return P such that A = P.L.U
    {p |> transpose_matrix() |> matrix_to_binary(p_type),
     l |> approximate_zeros(eps) |> matrix_to_binary(l_type),
     u |> approximate_zeros(eps) |> matrix_to_binary(u_type)}
  end

  defp lu_validate_and_pivot(a, n) do
    # pivots a tensor so that the biggest elements of each column lie on the diagonal.
    # if any of the diagonal elements ends up being 0, raises an ArgumentError

    identity =
      Enum.map(0..(n - 1), fn i -> Enum.map(0..(n - 1), fn j -> if i == j, do: 1, else: 0 end) end)

    # For each row, find the max value by column.
    # If its index (max_idx) is not in the diagonal (i.e. j != max_idx)
    # we need to swap rows j and max_idx in both the permutation matrix
    # and in the a matrix.
    Enum.reduce(0..(n - 2), {identity, a}, fn j, {p, a} ->
      [max_idx | _] =
        Enum.sort_by(j..(n - 1), fn i -> a |> Enum.at(i) |> Enum.at(j) |> abs() end, &>=/2)

      if max_idx == j do
        {p, a}
      else
        p_row = Enum.at(p, max_idx)
        p_j = Enum.at(p, j)
        p = p |> List.replace_at(max_idx, p_j) |> List.replace_at(j, p_row)

        a_row = Enum.at(a, max_idx)
        a_j = Enum.at(a, j)
        a = a |> List.replace_at(max_idx, a_j) |> List.replace_at(j, a_row)
        {p, a}
      end
    end)
  end

  ## Householder helpers

  defp householder_reflector(a, target_k, eps)

  defp householder_reflector([], target_k, _eps) do
    flat_list =
      for col <- 0..(target_k - 1), row <- 0..(target_k - 1), into: [] do
        if col == row, do: 1, else: 0
      end

    Enum.chunk_every(flat_list, target_k)
  end

  defp householder_reflector(a, target_k, eps) do
    {v, scale, is_complex} = householder_reflector_pivot(a, eps)

    prefix_threshold = target_k - length(v)
    v = List.duplicate(0, prefix_threshold) ++ v

    # dot(v, v) = norm_v_squared, which can be calculated from norm_a as:
    # norm_v_squared = norm_a_squared - a_0^2 + v_0^2

    # execute I - 2 / norm_v_squared * outer(v, v)
    {_, _, reflector_reversed} =
      for col_factor <- v, row_factor <- v, reduce: {0, 0, []} do
        {row, col, acc} ->
          row_factor = if is_complex, do: Complex.conjugate(row_factor), else: row_factor

          # The current element in outer(v, v) is given by col_factor * row_factor
          # and the current I element is 1 when row == col
          identity_element = if row == col, do: 1, else: 0

          result =
            if row >= prefix_threshold and col >= prefix_threshold do
              identity_element -
                scale * col_factor * row_factor
            else
              identity_element
            end

          acc = [result | acc]

          if col + 1 == target_k do
            {row + 1, 0, acc}
          else
            {row, col + 1, acc}
          end
      end

    # This is equivalent to reflector_reversed |> Enum.reverse() |> Enum.chunk_every(target_k)
    {reflector, _, _} =
      for x <- reflector_reversed, reduce: {[], [], 0} do
        {result_acc, row_acc, col} ->
          row_acc = [x | row_acc]

          if col + 1 == target_k do
            {[row_acc | result_acc], [], 0}
          else
            {result_acc, row_acc, col + 1}
          end
      end

    reflector
  end

  defp householder_reflector_pivot([a_0 | tail] = a, eps) when is_number(a_0) do
    # This is a trick so we can both calculate the norm of a_reverse and extract the
    # head a the same time we reverse the array
    # receives a_reverse as a list of numbers and returns the reflector as a
    # k x k matrix

    norm_a_squared = Enum.reduce(a, 0, fn x, acc -> x * Complex.conjugate(x) + acc end)
    norm_a_sq_1on = norm_a_squared - a_0 * a_0

    if norm_a_sq_1on < eps do
      {[1 | tail], 0, false}
    else
      v_0 =
        if a_0 <= 0 do
          a_0 - Complex.sqrt(norm_a_squared)
        else
          -norm_a_sq_1on / (a_0 + Complex.sqrt(norm_a_squared))
        end

      v_0_sq = v_0 * v_0
      scale = 2 * v_0_sq / (norm_a_sq_1on + v_0_sq)
      v = [1 | Enum.map(tail, &(&1 / v_0))]
      {v, scale, false}
    end
  end

  defp householder_reflector_pivot([a_0 | tail], _eps) do
    # complex case
    norm_a_sq_1on = Enum.reduce(tail, 0, &(Complex.abs_squared(&1) + &2))
    norm_a_sq = norm_a_sq_1on + Complex.abs_squared(a_0)
    norm_a = Complex.sqrt(norm_a_sq)

    phase_a_0 = Complex.phase(a_0)
    alfa = Complex.exp(Complex.new(0, phase_a_0)) * norm_a

    # u = x - alfa * e1
    u_0 = a_0 + alfa
    u = [u_0 | tail]
    norm_u_sq = norm_a_sq_1on + Complex.abs_squared(u_0)
    norm_u = Complex.sqrt(norm_u_sq)

    v = Enum.map(u, &(&1 / norm_u))
    {v, 2, true}
  end

  ## Matrix (2-D array) manipulation

  defp dot_matrix([], _), do: 0
  defp dot_matrix(_, []), do: 0

  defp dot_matrix([h1 | _] = v1, [h2 | _] = v2) when not is_list(h1) and not is_list(h2) do
    v1
    |> Enum.zip(v2)
    |> Enum.reduce(0, fn {x, y}, acc -> x * y + acc end)
  end

  defp dot_matrix(m1, m2) do
    # matrix multiplication which works on 2-D lists
    Enum.map(m1, fn row ->
      m2
      |> transpose_matrix()
      |> Enum.map(fn col ->
        row
        |> Enum.zip(col)
        |> Enum.reduce(0, fn {x, y}, acc -> acc + x * Complex.conjugate(y) end)
      end)
    end)
  end

  defp dot_matrix_real(m1, m2) do
    Enum.map(m1, fn row ->
      m2
      |> transpose_matrix()
      |> Enum.map(fn col ->
        row
        |> Enum.zip(col)
        |> Enum.reduce(0, fn {x, y}, acc -> acc + x * y end)
      end)
    end)
  end

  defp adjoint_matrix([x | _] = m) when not is_list(x) do
    Enum.map(m, &[Complex.conjugate(&1)])
  end

  defp adjoint_matrix(m) do
    Enum.zip_with(m, fn cols -> Enum.map(cols, &Complex.conjugate/1) end)
  end

  defp transpose_matrix([x | _] = m) when not is_list(x) do
    Enum.map(m, &[&1])
  end

  defp transpose_matrix(m) do
    Enum.zip_with(m, & &1)
  end

  defp matrix_to_binary([r | _] = m, type) when is_list(r) do
    match_types [type] do
      for row <- m, number <- row, into: "", do: <<write!(number, 0)>>
    end
  end

  defp matrix_to_binary(list, type) when is_list(list) do
    match_types [type] do
      for number <- list, into: "", do: <<write!(number, 0)>>
    end
  end

  defp binary_to_vector(bin, type) do
    match_types [type] do
      for <<match!(x, 0) <- bin>>, into: [], do: read!(x, 0)
    end
  end

  defp binary_to_matrix(bin, type, {_, num_cols}) do
    bin
    |> binary_to_vector(type)
    |> Enum.chunk_every(num_cols)
  end

  defp slice_matrix(a, [row_start, col_start], [row_length, col_length]) do
    a
    |> Enum.slice(row_start, row_length)
    |> Enum.flat_map(&Enum.slice(&1, col_start, col_length))
  end

  defp get_matrix_column(m, col) do
    Enum.map(m, fn row ->
      Enum.at(row, col)
    end)
  end

  defp get_matrix_columns(m, columns) do
    Enum.map(m, fn row ->
      for {item, i} <- Enum.with_index(row), i in columns, do: item
    end)
  end

  defp get_matrix_rows(m, rows) do
    for {row, i} <- Enum.with_index(m), i in rows, do: row
  end

  defp get_matrix_elements(m, row_col_pairs) do
    Enum.map(row_col_pairs, fn [row, col] ->
      m
      |> Enum.at(row, [])
      |> Enum.at(col)
      |> case do
        nil -> raise ArgumentError, "invalid index [#{row},#{col}] for matrix"
        item -> item
      end
    end)
  end

  defp replace_matrix_element(m, row, col, value) do
    updated = m |> Enum.at(row) |> List.replace_at(col, value)
    List.replace_at(m, row, updated)
  end

  defp approximate_zeros(matrix, tol) do
    do_round = fn x -> if Complex.abs(x) < tol, do: 0 * x, else: x end

    Enum.map(matrix, fn
      row when is_list(row) -> Enum.map(row, do_round)
      e -> do_round.(e)
    end)
  end
end
