defmodule Interview.Auth.Bootstrap do
  @moduledoc """
  Bootstrap-token mint/consume against `sessions` (PLAN §4.2).

  Single-use enforcement: each session row carries the latest minted
  `bootstrap_jti`. `consume/1` requires `jti == sessions.bootstrap_jti`
  AND `bootstrap_consumed_at == nil`, and atomically marks consumed.
  Re-mint via `mint/1` rotates the jti, invalidating the prior token.
  """
  import Ecto.Query, warn: false

  alias Interview.Repo
  alias Interview.Auth.Tokens
  alias Interview.Capture.Session

  @doc """
  Mint (or re-mint) a bootstrap token for the given session. Rotates the
  stored jti and clears any prior consumption stamp.
  """
  def mint(%Session{} = session) do
    {jti, token} = Tokens.mint_bootstrap(session.id, session.tenant_id)

    {1, [updated]} =
      from(s in Session, where: s.id == ^session.id, select: s)
      |> Repo.update_all(set: [bootstrap_jti: jti, bootstrap_consumed_at: nil])

    Interview.Audit.log!(%{
      tenant_id: session.tenant_id,
      actor_kind: "tenant_api_key",
      action: "bootstrap.mint",
      subject_kind: "session",
      subject_id: session.id,
      metadata: %{"jti" => jti}
    })

    {:ok, %{token: token, session: updated, jti: jti}}
  end

  @doc """
  Verify-only — checks that the token is valid AND not yet consumed
  AND the jti matches the current minted jti — without mutating state.

  Used on the LiveView HTTP mount (the "disconnected" mount) so the
  one-time consume only happens once on the WebSocket mount. Returns
  the same error shape as `consume/1`.
  """
  def peek(token) when is_binary(token) do
    with {:ok, %{sid: sid, jti: jti}} <- Tokens.verify_bootstrap(token) do
      case Repo.get(Session, sid) do
        nil ->
          {:error, :session_not_found}

        %Session{bootstrap_jti: ^jti, bootstrap_consumed_at: nil} = s ->
          {:ok, s}

        %Session{bootstrap_jti: ^jti} ->
          {:error, :consumed}

        _ ->
          {:error, :invalid}
      end
    end
  end

  def peek(_), do: {:error, :invalid}

  @doc """
  Verify + atomically consume a bootstrap token.

  Errors:
    * `:invalid` — bad signature, malformed payload, or jti doesn't match
      the session's latest minted jti.
    * `:expired` — token signature valid but TTL exceeded.
    * `:consumed` — token already consumed.
    * `:session_not_found` — payload references a session that no longer exists.
  """
  def consume(token) when is_binary(token) do
    with {:ok, %{sid: sid, tid: _tid, jti: jti}} <- Tokens.verify_bootstrap(token) do
      Repo.transaction(fn ->
        session =
          from(s in Session, where: s.id == ^sid, lock: "FOR UPDATE")
          |> Repo.one()

        cond do
          is_nil(session) ->
            Repo.rollback(:session_not_found)

          session.bootstrap_jti != jti ->
            Repo.rollback(:invalid)

          not is_nil(session.bootstrap_consumed_at) ->
            Repo.rollback(:consumed)

          true ->
            now = DateTime.utc_now()

            {1, [updated]} =
              from(s in Session, where: s.id == ^session.id, select: s)
              |> Repo.update_all(set: [bootstrap_consumed_at: now])

            updated
        end
      end)
      |> case do
        {:ok, %Session{} = session} ->
          Interview.Audit.log!(%{
            tenant_id: session.tenant_id,
            actor_kind: "candidate",
            action: "bootstrap.consume",
            subject_kind: "session",
            subject_id: session.id,
            metadata: %{"jti" => jti}
          })

          {:ok, session}

        {:error, reason} ->
          Interview.Audit.log!(%{
            actor_kind: "candidate",
            action: "bootstrap.refused",
            subject_kind: "session",
            subject_id: sid,
            metadata: %{"jti" => jti, "reason" => to_string(reason)}
          })

          {:error, reason}
      end
    end
  end

  def consume(_), do: {:error, :invalid}
end
