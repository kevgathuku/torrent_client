defmodule TorrentClient.WebseedHttpClient do
  @moduledoc """
  Real webseed HTTP implementation over raw `:hackney` streaming.

  Bodies are bounded *while reading*: the Range request already tells a
  compliant server how much to send, but the cap (`length + 1` parsed
  from our own Range header) is enforced chunk by chunk as bytes arrive,
  and the connection is torn down the moment it is exceeded — a
  Range-ignoring server can never make us buffer a whole file. Redirects
  (archive.org answers `/download/` with a 302 to a backend host) are
  followed manually with the same headers, up to 3 hops. Every wait is
  bounded by `@recv_timeout`, so a hung server fails the slice instead
  of wedging a worker slot forever.
  """

  @behaviour TorrentClient.WebseedHttpBehaviour

  @max_redirects 3
  @connect_timeout 10_000
  @recv_timeout 30_000
  @default_cap 4_194_304
  @redirect_statuses [301, 302, 303, 307, 308]

  @impl true
  def get(url, headers) do
    get(url, headers, @max_redirects)
  end

  defp get(url, headers, left) do
    # +1 distinguishes "exactly the slice" from "slice and more" while
    # buffering at most one extra byte.
    limit = range_cap(headers) + 1

    case :hackney.request(:get, url, headers, "", async_opts()) do
      {:ok, ref} -> await_status(ref, url, headers, left, limit)
      {:error, _} = err -> err
    end
  end

  defp async_opts do
    [:async, {:connect_timeout, @connect_timeout}, {:recv_timeout, @recv_timeout}]
  end

  defp await_status(ref, url, headers, left, limit) do
    receive do
      {:hackney_response, ^ref, {:status, status, _reason}} ->
        await_headers(ref, url, headers, left, limit, status)

      {:hackney_response, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      @recv_timeout -> {:error, :timeout}
    end
  end

  defp await_headers(ref, url, headers, left, limit, status) do
    receive do
      {:hackney_response, ^ref, {:headers, resp_headers}} ->
        handle_response(ref, url, headers, left, limit, status, resp_headers)

      {:hackney_response, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      @recv_timeout -> {:error, :timeout}
    end
  end

  defp handle_response(ref, url, headers, left, _limit, status, resp_headers)
       when status in @redirect_statuses and left > 0 do
    stop(ref)

    case location(resp_headers) do
      nil -> {:ok, %Tesla.Env{status: status, headers: resp_headers, body: ""}}
      next -> get(merge_url(url, next), headers, left - 1)
    end
  end

  defp handle_response(ref, _url, _headers, _left, _limit, status, resp_headers)
       when status in @redirect_statuses do
    stop(ref)
    {:error, :too_many_redirects}
  end

  defp handle_response(ref, _url, _headers, _left, limit, status, resp_headers) do
    read_chunks(ref, status, resp_headers, limit, [])
  end

  defp read_chunks(ref, status, resp_headers, remaining, acc) do
    receive do
      {:hackney_response, ^ref, :done} ->
        {:ok,
         %Tesla.Env{
           status: status,
           headers: resp_headers,
           body: acc |> Enum.reverse() |> IO.iodata_to_binary()
         }}

      {:hackney_response, ^ref, bin} when is_binary(bin) ->
        if byte_size(bin) > remaining do
          stop(ref)
          {:error, :body_too_large}
        else
          read_chunks(ref, status, resp_headers, remaining - byte_size(bin), [bin | acc])
        end

      {:hackney_response, ^ref, {:error, reason}} ->
        {:error, reason}
    after
      @recv_timeout -> {:error, :timeout}
    end
  end

  defp stop(ref) do
    try do
      :hackney.stop_async(ref)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp location(resp_headers) do
    Enum.find_value(resp_headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "location", do: value, else: nil

      _ ->
        nil
    end)
  end

  defp merge_url(url, next) do
    url |> URI.merge(next) |> URI.to_string()
  end

  # The cap comes from our own Range header (`bytes=a-b` fetches at most
  # `b - a + 1`); callers without one get a flat default instead of an
  # unbounded read.
  defp range_cap(headers) do
    Enum.find_value(headers, @default_cap, fn
      {name, "bytes=" <> rest} when is_binary(name) ->
        if String.downcase(name) == "range", do: parse_range(rest), else: nil

      _ ->
        nil
    end)
  end

  defp parse_range(rest) do
    case String.split(rest, "-") do
      [first, last] ->
        with {a, ""} <- Integer.parse(first),
             {b, ""} <- Integer.parse(last),
             true <- b >= a do
          b - a + 1
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
