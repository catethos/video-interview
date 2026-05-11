defmodule Interview.Auth.Recruiters do
  @moduledoc """
  Recruiter accounts + magic-link sign-in (PLAN §11 #8).

  v1 has no email infrastructure: `request_magic_link/2` logs the URL via
  `Logger.info` and returns the URL to its caller (tests use this directly).
  Real SMTP (Swoosh) is a follow-up. The HTTP endpoint never reveals the
  URL — the controller responds 202 unconditionally to avoid email
  enumeration.
  """
  require Logger
  import Ecto.Query, warn: false

  alias Interview.Repo
  alias Interview.Auth.Recruiters.{User, MagicLink}

  @magic_link_ttl_seconds 15 * 60
  @token_bytes 32

  # ---- Users --------------------------------------------------------------

  def get_user(id), do: Repo.get(User, id)
  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) when is_binary(email) do
    normalized = User.normalize_email(email)
    Repo.get_by(User, email: normalized)
  end

  def list_users(tenant_id) do
    from(u in User, where: u.tenant_id == ^tenant_id, order_by: u.email) |> Repo.all()
  end

  @doc """
  Create a recruiter for a tenant. Email is downcased + trimmed; uniqueness
  is global (one human, one email).
  """
  def create_user(attrs) do
    %User{} |> User.changeset(attrs) |> Repo.insert()
  end

  def create_user!(attrs) do
    {:ok, user} = create_user(attrs)
    user
  end

  def touch_seen(%User{} = user) do
    now = DateTime.utc_now()

    {1, _} =
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(set: [last_seen_at: now])

    %{user | last_seen_at: now}
  end

  # ---- Magic links --------------------------------------------------------

  @doc """
  Issue a magic link for the given email.

  Returns `{:ok, %{user, token, url}}` if the email maps to a known
  recruiter; `{:error, :not_found}` otherwise. The HTTP endpoint discards
  this return value (always 202) to avoid enumeration; tests use it
  directly so they don't need to scrape logs.

  The `token` returned is the unhashed wire token (this is the only place
  it ever exists in plaintext on the server side; only its sha256 lives
  in the DB).
  """
  def request_magic_link(email, requested_ip \\ nil)
      when is_binary(email) do
    case get_user_by_email(email) do
      nil ->
        {:error, :not_found}

      %User{} = user ->
        raw = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
        hash = :crypto.hash(:sha256, raw)
        expires_at = DateTime.utc_now() |> DateTime.add(@magic_link_ttl_seconds, :second)

        {:ok, _} =
          %MagicLink{}
          |> MagicLink.changeset(%{
            recruiter_user_id: user.id,
            token_hash: hash,
            expires_at: expires_at,
            requested_ip: requested_ip
          })
          |> Repo.insert()

        url = magic_link_url(raw)
        Logger.info("magic_link_url=#{url} email=#{user.email}")

        Interview.Audit.log!(%{
          tenant_id: user.tenant_id,
          actor_kind: "recruiter",
          actor_id: user.id,
          action: "magic_link.request",
          subject_kind: "recruiter_user",
          subject_id: user.id,
          ip_address: requested_ip
        })

        {:ok, %{user: user, token: raw, url: url}}
    end
  end

  @doc """
  Consume a raw magic-link token. Marks consumed in DB on success and
  rejects double-consume + expired.
  """
  def consume_magic_link(raw) when is_binary(raw) do
    hash = :crypto.hash(:sha256, raw)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      link =
        from(l in MagicLink, where: l.token_hash == ^hash, lock: "FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(link) ->
          Repo.rollback(:invalid)

        not is_nil(link.consumed_at) ->
          Repo.rollback(:consumed)

        DateTime.compare(link.expires_at, now) != :gt ->
          Repo.rollback(:expired)

        true ->
          {1, _} =
            from(l in MagicLink, where: l.id == ^link.id)
            |> Repo.update_all(set: [consumed_at: now])

          user = Repo.get!(User, link.recruiter_user_id)
          touch_seen(user)
      end
    end)
    |> case do
      {:ok, %User{} = user} ->
        Interview.Audit.log!(%{
          tenant_id: user.tenant_id,
          actor_kind: "recruiter",
          actor_id: user.id,
          action: "magic_link.consume",
          subject_kind: "recruiter_user",
          subject_id: user.id
        })

        {:ok, user}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def consume_magic_link(_), do: {:error, :invalid}

  defp magic_link_url(raw) do
    InterviewWeb.Endpoint.url() <> "/auth/magic-link/" <> raw
  end
end
