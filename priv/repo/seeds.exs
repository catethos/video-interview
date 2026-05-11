# Dev seeds: a single tenant + template + version + one question, used
# by the `/capture/new` LiveView shortcut to spin up a fresh session
# without the (Phase 2) recruiter authoring UI.

import Ecto.Query, only: [from: 2]

alias Interview.Repo
alias Interview.Tenants.Tenant
alias Interview.Templates.{Template, Version, Question}

tenant =
  case Repo.get_by(Tenant, slug: "dev") do
    nil ->
      {:ok, t} =
        %Tenant{}
        |> Tenant.changeset(%{
          name: "Dev Tenant",
          slug: "dev",
          frame_ancestors: ["'self'", "http://127.0.0.1:5174", "http://localhost:5174"]
        })
        |> Repo.insert()

      t

    existing ->
      existing
  end

template =
  case Repo.get_by(Template, tenant_id: tenant.id, name: "Dev Template") do
    nil ->
      {:ok, t} =
        %Template{}
        |> Template.changeset(%{tenant_id: tenant.id, name: "Dev Template"})
        |> Repo.insert()

      t

    existing ->
      existing
  end

version =
  Repo.get_by(Version, template_id: template.id, version_number: 1) ||
    (
      {:ok, v} =
        %Version{}
        |> Version.changeset(%{
          template_id: template.id,
          version_number: 1,
          published_at: DateTime.utc_now()
        })
        |> Repo.insert()

      v
    )

unless Repo.get_by(Question, template_version_id: version.id, position: 1) do
  {:ok, _} =
    %Question{}
    |> Question.changeset(%{
      template_version_id: version.id,
      position: 1,
      prompt_text: "Tell us about a time you had to debug something hard under time pressure.",
      max_answer_seconds: 120,
      think_time_seconds: 15,
      required: true,
      tags: ["behavioral"]
    })
    |> Repo.insert()
end

# Snap the template's pointer to v1 so /capture/new finds a published version.
unless template.current_version_id == version.id do
  {:ok, _} =
    template
    |> Template.changeset(%{current_version_id: version.id})
    |> Repo.update()
end

IO.puts("Dev seeds in place: tenant=#{tenant.slug} template=#{template.id} version=#{version.id}")

# ---- Auth seeds (dev recruiter + dev API key) ---------------------------
#
# `Interview.Auth.Recruiters` looks up by email; idempotent — re-running
# seeds is a no-op for existing records. Dev API key is minted only on
# first run (its secret can't be recovered after that).

alias Interview.Auth.{ApiKeys, Recruiters}
alias Interview.Auth.Recruiters.User

dev_email = "dev@example.com"

dev_recruiter =
  case Recruiters.get_user_by_email(dev_email) do
    %User{} = u ->
      u

    nil ->
      Recruiters.create_user!(%{
        tenant_id: tenant.id,
        email: dev_email,
        role: "owner"
      })
  end

if Repo.aggregate(
     from(k in Interview.Auth.ApiKeys.ApiKey, where: k.tenant_id == ^tenant.id),
     :count,
     :id
   ) == 0 do
  {:ok, %{api_key: _key, secret: secret}} =
    ApiKeys.create(tenant.id, "dev-default", dev_recruiter.id)

  IO.puts("Minted dev API key. Save the bearer (it won't be shown again):")
  IO.puts("  #{secret}")
end

IO.puts("Dev recruiter: #{dev_recruiter.email}")

IO.puts(
  "Magic-link sign-in: POST http://localhost:4000/api/auth/magic-links {\"email\":\"#{dev_recruiter.email}\"}; the URL prints in the server log."
)
