defmodule Interview.Playback do
  @moduledoc """
  Read-only queries powering the recruiter playback UI (PLAN — playback-plan.md).

  All queries are tenant-scoped; callers pass the recruiter's tenant_id and
  receive only rows owned by that tenant. Cross-tenant reads return `nil`
  rather than raising so the controller can answer 404 without leaking
  existence.
  """

  import Ecto.Query, warn: false

  alias Interview.Capture.{Response, Session, SessionQuestion}
  alias Interview.Repo
  alias Interview.Templates.{Question, Template, Version}
  alias Interview.Webhooks.Delivery

  @session_states ~w(pending in_progress submitted ready failed expired)

  def session_states, do: @session_states

  @doc """
  Sessions for the recruiter dashboard list page.

  Options:
    * `:states` — list of session states to include (default: all).
    * `:template_id` — filter to one template (across all its versions).

  Each row carries: `template_name`, `version_number`, `question_count`,
  `total_duration_ms` (sum of selected response durations), plus the raw
  Session fields. Ordered `completed_at desc nulls last, inserted_at desc`.
  """
  def list_sessions(tenant_id, opts \\ []) when is_binary(tenant_id) do
    states = Keyword.get(opts, :states)
    template_id = Keyword.get(opts, :template_id)

    base =
      from(s in Session,
        join: v in Version,
        on: v.id == s.template_version_id,
        join: t in Template,
        on: t.id == v.template_id,
        where: s.tenant_id == ^tenant_id and is_nil(s.deleted_at),
        left_join: sq in SessionQuestion,
        on: sq.session_id == s.id,
        left_join: r in Response,
        on: r.id == sq.selected_response_id,
        group_by: [s.id, v.version_number, t.name],
        order_by: [
          fragment("? DESC NULLS LAST", s.completed_at),
          desc: s.inserted_at
        ],
        select: %{
          session: s,
          template_name: t.name,
          version_number: v.version_number,
          question_count: count(sq.id),
          total_duration_ms: coalesce(sum(r.duration_ms), 0)
        }
      )

    base
    |> maybe_filter_states(states)
    |> maybe_filter_template(template_id)
    |> Repo.all()
  end

  defp maybe_filter_states(query, nil), do: query
  defp maybe_filter_states(query, []), do: query

  defp maybe_filter_states(query, states) when is_list(states) do
    from([s, _v, _t, _sq, _r] in query, where: s.state in ^states)
  end

  defp maybe_filter_template(query, nil), do: query

  defp maybe_filter_template(query, template_id) do
    from([_s, v, _t, _sq, _r] in query, where: v.template_id == ^template_id)
  end

  @doc """
  Templates that this tenant has at least one session for. Used to populate
  the list-page filter dropdown so we don't show templates with zero
  recordings.
  """
  def list_templates_with_sessions(tenant_id) when is_binary(tenant_id) do
    from(s in Session,
      join: v in Version,
      on: v.id == s.template_version_id,
      join: t in Template,
      on: t.id == v.template_id,
      where: s.tenant_id == ^tenant_id and is_nil(s.deleted_at),
      group_by: [t.id, t.name],
      order_by: [asc: t.name],
      select: %{id: t.id, name: t.name}
    )
    |> Repo.all()
  end

  @doc """
  Full detail for the per-session page. Returns:

      %{
        session: %Session{},
        template: %Template{},
        version: %Version{},
        questions: [
          %{
            template_question: %Question{},
            session_question: %SessionQuestion{},
            selected_response: %Response{} | nil,
            attempts: [%Response{}]   # all attempts ordered by attempt_number
          }
        ],
        webhook_summary: %{event_type => state_count_map}
      }

  Returns `nil` if the session does not exist or belongs to another tenant.
  """
  def get_session(tenant_id, session_id)
      when is_binary(tenant_id) and is_binary(session_id) do
    query =
      from(s in Session,
        where: s.id == ^session_id and s.tenant_id == ^tenant_id and is_nil(s.deleted_at)
      )

    case Repo.one(query) do
      nil ->
        nil

      %Session{} = session ->
        version = Repo.get!(Version, session.template_version_id)
        template = Repo.get!(Template, version.template_id)

        questions = load_question_cards(session, version.id)

        webhook_summary = load_webhook_summary(session.id)

        %{
          session: session,
          template: template,
          version: version,
          questions: questions,
          webhook_summary: webhook_summary
        }
    end
  end

  defp load_question_cards(%Session{} = session, version_id) do
    template_questions =
      from(q in Question,
        where: q.template_version_id == ^version_id,
        order_by: q.position
      )
      |> Repo.all()

    session_questions_by_qid =
      from(sq in SessionQuestion, where: sq.session_id == ^session.id)
      |> Repo.all()
      |> Map.new(fn sq -> {sq.template_question_id, sq} end)

    responses_by_qid =
      from(r in Response,
        where: r.session_id == ^session.id,
        order_by: r.attempt_number
      )
      |> Repo.all()
      |> Enum.group_by(& &1.template_question_id)

    Enum.map(template_questions, fn q ->
      sq = Map.get(session_questions_by_qid, q.id)
      attempts = Map.get(responses_by_qid, q.id, [])

      selected =
        case sq && sq.selected_response_id do
          nil -> nil
          rid -> Enum.find(attempts, &(&1.id == rid))
        end

      %{
        template_question: q,
        session_question: sq,
        selected_response: selected,
        attempts: attempts
      }
    end)
  end

  defp load_webhook_summary(session_id) do
    from(d in Delivery,
      where: d.session_id == ^session_id,
      group_by: [d.event_type, d.state],
      select: {d.event_type, d.state, count(d.id)}
    )
    |> Repo.all()
    |> Enum.group_by(fn {event_type, _state, _n} -> event_type end, fn {_e, state, n} ->
      {state, n}
    end)
    |> Map.new(fn {event_type, pairs} -> {event_type, Map.new(pairs)} end)
  end

  @doc """
  Lookup used by the playback controller. Returns the response *only* if it
  belongs to a session owned by `tenant_id`. Returns `nil` otherwise — the
  controller turns that into a 404 (deliberately not 403, to avoid leaking
  the existence of cross-tenant rows).
  """
  def get_response_for_playback(tenant_id, response_id)
      when is_binary(tenant_id) and is_binary(response_id) do
    from(r in Response,
      join: s in Session,
      on: s.id == r.session_id,
      where: r.id == ^response_id and s.tenant_id == ^tenant_id and is_nil(s.deleted_at),
      select: r
    )
    |> Repo.one()
  end
end
