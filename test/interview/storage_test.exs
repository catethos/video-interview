defmodule Interview.StorageTest do
  use ExUnit.Case, async: true

  alias Interview.Storage

  setup do
    rid = "rid-#{System.unique_integer([:positive])}"
    cid = "cid-#{System.unique_integer([:positive])}"
    on_exit(fn -> Storage.delete_response(rid) end)
    {:ok, rid: rid, cid: cid}
  end

  test "first write at offset 0 succeeds and returns the new size",
       %{rid: rid, cid: cid} do
    assert {:ok, 5} = Storage.put_at_offset(rid, cid, 0, "hello")
    assert {:ok, 5} = Storage.writer_size(rid, cid)
  end

  test "subsequent writes advance the offset", %{rid: rid, cid: cid} do
    {:ok, 5} = Storage.put_at_offset(rid, cid, 0, "hello")
    {:ok, 11} = Storage.put_at_offset(rid, cid, 5, "-world")
    assert {:ok, 11} = Storage.writer_size(rid, cid)
  end

  test "wrong offset reports the current size for resync",
       %{rid: rid, cid: cid} do
    {:ok, 5} = Storage.put_at_offset(rid, cid, 0, "hello")
    assert {:error, {:offset_mismatch, 5}} = Storage.put_at_offset(rid, cid, 99, "boom")
  end

  test "replay of already-written bytes is accepted (idempotent)",
       %{rid: rid, cid: cid} do
    {:ok, 5} = Storage.put_at_offset(rid, cid, 0, "hello")
    # Replay the same first byte: offset < current and within range.
    assert {:ok, 5} = Storage.put_at_offset(rid, cid, 0, "h")
    assert {:ok, 5} = Storage.writer_size(rid, cid)
  end

  test "different capture instances on the same response are independent",
       %{rid: rid} do
    cid_a = "cap-A"
    cid_b = "cap-B"
    on_exit(fn -> Storage.delete_response(rid) end)

    {:ok, 3} = Storage.put_at_offset(rid, cid_a, 0, "AAA")
    {:ok, 4} = Storage.put_at_offset(rid, cid_b, 0, "BBBB")

    assert {:ok, 3} = Storage.writer_size(rid, cid_a)
    assert {:ok, 4} = Storage.writer_size(rid, cid_b)
  end
end
