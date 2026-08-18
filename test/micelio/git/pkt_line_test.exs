defmodule Micelio.Git.PktLineTest do
  use ExUnit.Case, async: true

  alias Micelio.Git.PktLine

  test "encodes the length inclusive of the four-byte prefix" do
    assert PktLine.encode("a") == "0005a"
    assert PktLine.encode("hello\n") == "000ahello\n"
  end

  test "refuses an oversized payload rather than truncating it" do
    assert_raise ArgumentError, fn -> PktLine.encode(String.duplicate("x", 70_000)) end
  end

  test "the service header is what makes git use the smart protocol" do
    assert PktLine.service_header("git-upload-pack") == "001e# service=git-upload-pack\n0000"
  end

  describe "decode/1" do
    test "reads a sequence of packets" do
      data = PktLine.encode("one\n") <> PktLine.encode("two\n") <> PktLine.flush()
      assert {["one\n", "two\n", :flush], ""} = PktLine.decode(data)
    end

    test "recognises the special zero-length packets" do
      data = PktLine.flush() <> PktLine.delim() <> PktLine.response_end()
      assert {[:flush, :delim, :response_end], ""} = PktLine.decode(data)
    end

    test "returns a partial packet as remaining bytes so a reader can resume" do
      full = PktLine.encode("complete\n")
      partial = String.slice(PktLine.encode("incomplete\n"), 0, 6)

      assert {["complete\n"], rest} = PktLine.decode(full <> partial)
      assert rest == partial
    end

    test "round trips" do
      payloads = ["a", "bb\n", String.duplicate("z", 1000)]
      encoded = Enum.map_join(payloads, &PktLine.encode/1)
      assert {^payloads, ""} = PktLine.decode(encoded)
    end
  end

  test "sideband framing marks the channel git prints from" do
    assert <<_len::binary-size(4), 2, "hi\n">> = PktLine.sideband_message("hi")
    assert <<_len::binary-size(4), 3, "bad\n">> = PktLine.sideband_error("bad")
  end
end
