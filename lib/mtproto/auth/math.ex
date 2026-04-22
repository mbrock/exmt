defmodule MTProto.Auth.Math do
  @moduledoc false

  import Bitwise, only: [<<<: 2]

  @dh_safety_range 1 <<< (2048 - 64)

  @spec factor_pq(binary() | pos_integer()) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, term()}
  def factor_pq(value) when is_binary(value) and byte_size(value) > 0 do
    value |> :binary.decode_unsigned() |> factor_pq()
  end

  def factor_pq(value) when is_integer(value) and value > 3 do
    cond do
      rem(value, 2) == 0 ->
        {:ok, order_factors(2, div(value, 2))}

      true ->
        case pollard_rho(value) do
          nil -> {:error, :factorization_failed}
          factor -> {:ok, order_factors(factor, div(value, factor))}
        end
    end
  end

  def factor_pq(_), do: {:error, :invalid_pq}

  @spec mod_pow(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  def mod_pow(_base, 0, modulus), do: rem(1, modulus)

  def mod_pow(base, exponent, modulus)
      when is_integer(base) and base >= 0 and is_integer(exponent) and
             exponent >= 0 and
             is_integer(modulus) and modulus > 0 do
    do_mod_pow(rem(base, modulus), exponent, modulus, 1)
  end

  @spec validate_dh(
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          :ok | {:error, term()}
  def validate_dh(dh_prime, g, g_a, g_b)
      when is_integer(dh_prime) and dh_prime > 0 and is_integer(g) and g > 0 and
             is_integer(g_a) and g_a > 0 and is_integer(g_b) and g_b > 0 do
    with :ok <- check_range(g, 1, dh_prime - 1, :bad_g),
         :ok <- check_range(g_a, 1, dh_prime - 1, :bad_g_a),
         :ok <- check_range(g_b, 1, dh_prime - 1, :bad_g_b),
         :ok <-
           check_range(
             g_a,
             @dh_safety_range,
             dh_prime - @dh_safety_range,
             :unsafe_g_a
           ),
         :ok <-
           check_range(
             g_b,
             @dh_safety_range,
             dh_prime - @dh_safety_range,
             :unsafe_g_b
           ) do
      :ok
    end
  end

  def validate_dh(_dh_prime, _g, _g_a, _g_b), do: {:error, :invalid_dh_params}

  @spec encode_unsigned(non_neg_integer()) :: binary()
  def encode_unsigned(value) when is_integer(value) and value >= 0,
    do: :binary.encode_unsigned(value)

  @spec encode_unsigned(non_neg_integer(), pos_integer()) :: binary()
  def encode_unsigned(value, size)
      when is_integer(value) and value >= 0 and is_integer(size) and size > 0 do
    encoded = :binary.encode_unsigned(value)
    padding = size - byte_size(encoded)

    cond do
      padding < 0 ->
        raise ArgumentError, "integer does not fit into #{size} bytes"

      padding == 0 ->
        encoded

      true ->
        <<0::size(padding)-unit(8), encoded::binary>>
    end
  end

  @spec reverse_bytes(binary()) :: binary()
  def reverse_bytes(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :erlang.list_to_binary()
  end

  @spec increment_be(binary()) :: binary()
  def increment_be(value) when is_binary(value) and byte_size(value) > 0 do
    size = byte_size(value)
    modulus = 1 <<< (size * 8)

    value
    |> :binary.decode_unsigned()
    |> Kernel.+(1)
    |> rem(modulus)
    |> encode_unsigned(size)
  end

  defp do_mod_pow(_base, 0, _modulus, acc), do: acc

  defp do_mod_pow(base, exponent, modulus, acc) do
    acc =
      if rem(exponent, 2) == 1 do
        rem(acc * base, modulus)
      else
        acc
      end

    do_mod_pow(rem(base * base, modulus), div(exponent, 2), modulus, acc)
  end

  defp pollard_rho(value) do
    Enum.find_value(1..32, fn c ->
      walk_pollard(value, c, 2, 2, 0)
    end)
  end

  defp walk_pollard(_value, _c, _x, _y, 250_000), do: nil

  defp walk_pollard(value, c, x, y, steps) do
    x1 = pollard_step(x, c, value)
    y1 = pollard_step(pollard_step(y, c, value), c, value)
    divisor = Integer.gcd(abs(x1 - y1), value)

    cond do
      divisor == 1 -> walk_pollard(value, c, x1, y1, steps + 1)
      divisor == value -> nil
      true -> divisor
    end
  end

  defp pollard_step(x, c, modulus), do: rem(x * x + c, modulus)

  defp order_factors(left, right) when left <= right, do: {left, right}
  defp order_factors(left, right), do: {right, left}

  defp check_range(value, lower, upper, _reason)
       when value > lower and value < upper,
       do: :ok

  defp check_range(_value, _lower, _upper, reason), do: {:error, reason}
end
