defmodule Micelio.Git.PktLine do
  @moduledoc """
  Git's pkt-line framing.

  A packet is a four-character hexadecimal length followed by that many bytes,
  the length being inclusive of the four characters themselves. Three lengths
  are special and carry no payload: `0000` ends a section, `0001` delimits one,
  and `0002` marks the end of a response in protocol v2.

  Micelio only frames the small amount of protocol it generates itself — the
  service header on the reference advertisement, and error messages that have
  to reach a `git` client's terminal. Everything else is produced by `git` and
  passed through untouched.
  """

  @flush "0000"
  @delim "0001"
  @response_end "0002"

  @doc "Frame a payload as a pkt-line."
  @spec encode(iodata()) :: binary()
  def encode(payload) do
    payload = IO.iodata_to_binary(payload)
    length = byte_size(payload) + 4

    if length > 65_520 do
      raise ArgumentError, "pkt-line payload exceeds the 65516 byte maximum"
    end

    (length |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")) <> payload
  end

  @doc "The flush packet that ends a section."
  @spec flush() :: binary()
  def flush, do: @flush

  @doc "The delimiter packet used between protocol v2 sections."
  @spec delim() :: binary()
  def delim, do: @delim

  @doc "The packet that ends a protocol v2 response."
  @spec response_end() :: binary()
  def response_end, do: @response_end

  @doc """
  The service header that must precede a smart-HTTP advertisement.

  Git checks for this exact framing to decide whether it is talking to a smart
  server or a dumb one, so it is emitted by us rather than by `git`.
  """
  @spec service_header(String.t()) :: binary()
  def service_header(service), do: encode("# service=#{service}\n") <> @flush

  @doc """
  Frame a message so a `git` client prints it to the user.

  Used to explain a rejected push. Without the sideband framing the text is
  swallowed and the user is left with an unexplained failure.
  """
  @spec sideband_message(String.t()) :: binary()
  def sideband_message(text) do
    encode(<<2>> <> text <> "\n")
  end

  @doc "Frame a fatal error on the error sideband."
  @spec sideband_error(String.t()) :: binary()
  def sideband_error(text), do: encode(<<3>> <> text <> "\n")

  @doc """
  Parse a stream of pkt-lines.

  Returns the decoded payloads and whatever trailing bytes did not form a
  complete packet, so a caller reading from a socket can resume.
  """
  @spec decode(binary()) :: {[binary() | :flush | :delim | :response_end], binary()}
  def decode(data), do: decode(data, [])

  defp decode(<<length::binary-size(4), rest::binary>> = data, acc) do
    case Integer.parse(length, 16) do
      {0, ""} ->
        decode(rest, [:flush | acc])

      {1, ""} ->
        decode(rest, [:delim | acc])

      {2, ""} ->
        decode(rest, [:response_end | acc])

      {n, ""} when n >= 4 ->
        payload_size = n - 4

        case rest do
          <<payload::binary-size(^payload_size), tail::binary>> -> decode(tail, [payload | acc])
          _ -> {Enum.reverse(acc), data}
        end

      _ ->
        {Enum.reverse(acc), data}
    end
  end

  defp decode(rest, acc), do: {Enum.reverse(acc), rest}
end
