defmodule Interview.Auth.ApiKeys do
  @moduledoc """
  Tenant-scoped server-to-server API keys (PLAN §4.2).

  Wire format: `Authorization: Bearer tk_<secret>`. The leading `tk_`
  disambiguates from `rk_` recruiter session tokens at the plug layer.

  Storage: only `prefix` (lookup) + `key_hash` (sha256 of secret) live in
  the DB. The plaintext secret is returned **once** from `create/3` and
  never again.
  """
  import Ecto.Query, warn: false

  alias Interview.Repo
  alias Interview.Auth.ApiKeys.ApiKey

  @prefix "tk_"
  @prefix_len 9
  @secret_bytes 32

  def list(tenant_id) do
    from(k in ApiKey, where: k.tenant_id == ^tenant_id, order_by: [desc: k.inserted_at])
    |> Repo.all()
  end

  def get(tenant_id, id) do
    case Repo.get(ApiKey, id) do
      %ApiKey{tenant_id: ^tenant_id} = k -> {:ok, k}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Mint a new API key for `tenant_id`. Returns `{:ok, %{api_key, secret}}`
  where `secret` is the plaintext bearer (`tk_<...>`); store it where
  you'll use it, we don't keep a copy.
  """
  def create(tenant_id, name, created_by_id \\ nil) when is_binary(name) do
    raw = :crypto.strong_rand_bytes(@secret_bytes) |> Base.url_encode64(padding: false)
    prefix = @prefix <> String.slice(raw, 0, @prefix_len)
    bearer = @prefix <> raw
    hash = :crypto.hash(:sha256, raw)

    case %ApiKey{}
         |> ApiKey.changeset(%{
           tenant_id: tenant_id,
           name: name,
           prefix: prefix,
           key_hash: hash,
           created_by_id: created_by_id
         })
         |> Repo.insert() do
      {:ok, key} ->
        Interview.Audit.log!(%{
          tenant_id: tenant_id,
          actor_kind: "recruiter",
          actor_id: created_by_id,
          action: "api_key.create",
          subject_kind: "tenant_api_key",
          subject_id: key.id,
          metadata: %{"name" => name, "prefix" => prefix}
        })

        {:ok, %{api_key: key, secret: bearer}}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def revoke(tenant_id, id) do
    case get(tenant_id, id) do
      {:ok, %ApiKey{revoked_at: nil} = key} ->
        {1, [updated]} =
          from(k in ApiKey, where: k.id == ^key.id, select: k)
          |> Repo.update_all(set: [revoked_at: DateTime.utc_now()])

        Interview.Audit.log!(%{
          tenant_id: tenant_id,
          actor_kind: "recruiter",
          action: "api_key.revoke",
          subject_kind: "tenant_api_key",
          subject_id: key.id,
          metadata: %{"name" => key.name, "prefix" => key.prefix}
        })

        {:ok, updated}

      {:ok, %ApiKey{} = key} ->
        {:ok, key}

      err ->
        err
    end
  end

  @doc """
  Verify a bearer string. Accepts the wire format `tk_<secret>`. Returns
  `{:ok, %ApiKey{}}` (with `:tenant` preloaded) on success.
  """
  def verify(@prefix <> raw) when is_binary(raw) do
    do_verify(raw)
  end

  def verify(_), do: {:error, :invalid}

  defp do_verify(raw) do
    prefix = @prefix <> String.slice(raw, 0, @prefix_len)
    expected_hash = :crypto.hash(:sha256, raw)

    case Repo.get_by(ApiKey, prefix: prefix) do
      nil ->
        {:error, :invalid}

      %ApiKey{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %ApiKey{key_hash: stored} = key ->
        if Plug.Crypto.secure_compare(stored, expected_hash) do
          touch_used_async(key.id)
          {:ok, Repo.preload(key, :tenant)}
        else
          {:error, :invalid}
        end
    end
  end

  defp touch_used_async(id) do
    # Inline under tests so the SQL sandbox owner sees the write and we
    # don't get owner-exited noise from a detached Task.
    if Application.get_env(:interview, :async_touch?, true) do
      Task.Supervisor.start_child(Interview.TaskSupervisor, fn ->
        from(k in ApiKey, where: k.id == ^id)
        |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
      end)
    else
      from(k in ApiKey, where: k.id == ^id)
      |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
    end

    :ok
  rescue
    _ -> :ok
  end
end
