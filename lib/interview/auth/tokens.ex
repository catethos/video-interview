defmodule Interview.Auth.Tokens do
  @moduledoc """
  Token mint/verify wrapper over `Phoenix.Token` (PLAN §4.2 / §11 #8).

  Phoenix.Token is HMAC-signed structured payload using the endpoint's
  `secret_key_base`. For our use case nobody outside the app verifies our
  tokens, so we don't need the JWS/JWT envelope; the security properties
  (integrity + freshness via `max_age`) match.

  Three token types, each with its own salt + TTL:

    * **bootstrap** (`embed:bootstrap`) — single-use embed handshake. ≤5 min.
      Carries `%{sid, tid, jti}`. Single-use enforcement is at the
      `Interview.Auth.Bootstrap` layer (DB-checked `bootstrap_jti`).

    * **upload bearer** (`upload:bearer`) — refreshable tus auth. ≤60 min.
      Carries `%{sid}`. Stateless verification.

    * **recruiter session** (`recruiter:session`) — dashboard auth. ≤24 h.
      Carries `%{rid, tid}`. Returned with an `rk_` prefix on the wire so
      `TenantAuth` can disambiguate from `tk_*` API keys.
  """

  alias InterviewWeb.Endpoint

  @bootstrap_salt "embed:bootstrap"
  @bootstrap_max_age 300

  @upload_salt "upload:bearer"
  @upload_max_age 3600

  @recruiter_upload_salt "recruiter:upload:bearer"
  @recruiter_upload_max_age 3600

  @recruiter_salt "recruiter:session"
  @recruiter_max_age 86_400
  @recruiter_prefix "rk_"

  @playback_url_salt "playback:url"
  @playback_url_max_age 3600

  # ---- Bootstrap -----------------------------------------------------------

  def mint_bootstrap(session_id, tenant_id) when is_binary(session_id) and is_binary(tenant_id) do
    jti = Ecto.UUID.generate()
    payload = %{sid: session_id, tid: tenant_id, jti: jti}
    {jti, Phoenix.Token.sign(Endpoint, @bootstrap_salt, payload)}
  end

  def verify_bootstrap(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @bootstrap_salt, token, max_age: @bootstrap_max_age) do
      {:ok, %{sid: _, tid: _, jti: _} = payload} -> {:ok, payload}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify_bootstrap(_), do: {:error, :invalid}

  # ---- Upload bearer -------------------------------------------------------

  def mint_upload_bearer(session_id) when is_binary(session_id) do
    Phoenix.Token.sign(Endpoint, @upload_salt, %{sid: session_id})
  end

  def verify_upload_bearer(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @upload_salt, token, max_age: @upload_max_age) do
      {:ok, %{sid: sid}} -> {:ok, %{sid: sid}}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify_upload_bearer(_), do: {:error, :invalid}

  def upload_bearer_max_age, do: @upload_max_age

  # ---- Recruiter upload bearer --------------------------------------------

  @doc """
  Short-lived bearer for recruiter prompt-asset uploads (PLAN §3.4
  recruiter prompts). Carries `%{rid, tid}` so the tus plug can scope
  the asset id check against the tenant the recruiter belongs to.
  """
  def mint_recruiter_upload_bearer(recruiter_id, tenant_id)
      when is_binary(recruiter_id) and is_binary(tenant_id) do
    Phoenix.Token.sign(Endpoint, @recruiter_upload_salt, %{rid: recruiter_id, tid: tenant_id})
  end

  def verify_recruiter_upload_bearer(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @recruiter_upload_salt, token,
           max_age: @recruiter_upload_max_age
         ) do
      {:ok, %{rid: rid, tid: tid}} -> {:ok, %{rid: rid, tid: tid}}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify_recruiter_upload_bearer(_), do: {:error, :invalid}

  def recruiter_upload_bearer_max_age, do: @recruiter_upload_max_age

  # ---- Recruiter session ---------------------------------------------------

  def mint_recruiter_session(recruiter_id, tenant_id)
      when is_binary(recruiter_id) and is_binary(tenant_id) do
    @recruiter_prefix <>
      Phoenix.Token.sign(Endpoint, @recruiter_salt, %{rid: recruiter_id, tid: tenant_id})
  end

  def verify_recruiter_session(@recruiter_prefix <> rest) do
    do_verify_recruiter(rest)
  end

  def verify_recruiter_session(token) when is_binary(token) do
    # Accept the bare token too (cookie storage drops the prefix to keep it small).
    do_verify_recruiter(token)
  end

  def verify_recruiter_session(_), do: {:error, :invalid}

  defp do_verify_recruiter(token) do
    case Phoenix.Token.verify(Endpoint, @recruiter_salt, token, max_age: @recruiter_max_age) do
      {:ok, %{rid: rid, tid: tid}} -> {:ok, %{rid: rid, tid: tid}}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def recruiter_session_max_age, do: @recruiter_max_age
  def recruiter_prefix, do: @recruiter_prefix

  # ---- Playback URL token --------------------------------------------------

  @doc """
  Short-lived signed URL token for embedding a response's MP4 in an
  external recruiter dashboard (PLAN §8.5 change 3).

  Carries `%{rid, tid}` — the response id this token authorizes, scoped to
  a single tenant. The playback controller verifies BOTH that the token is
  valid AND that the requested response id matches the payload's `rid`, so
  a leaked token can never be repurposed for a different response.

  TTL: 1 hour. Leaked URLs die on their own; no revocation surface needed.
  """
  def mint_playback_url_token(response_id, tenant_id)
      when is_binary(response_id) and is_binary(tenant_id) do
    Phoenix.Token.sign(Endpoint, @playback_url_salt, %{rid: response_id, tid: tenant_id})
  end

  def verify_playback_url_token(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @playback_url_salt, token, max_age: @playback_url_max_age) do
      {:ok, %{rid: rid, tid: tid}} -> {:ok, %{rid: rid, tid: tid}}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify_playback_url_token(_), do: {:error, :invalid}

  def playback_url_max_age, do: @playback_url_max_age
end
