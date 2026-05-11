defmodule InterviewWeb.DocsLive do
  @moduledoc """
  In-app rendering of the markdown docs that ship in `docs/*.md`.

  The doc is loaded at compile time (`@external_resource`) so editing
  the markdown file triggers a recompile in dev — no app restart needed
  to see edits.

  Supported docs are whitelisted in `@docs` to avoid an arbitrary file
  read. Add a new entry here when a new doc should be browsable.
  """
  use InterviewWeb, :live_view

  alias InterviewWeb.Markdown

  @docs_dir Path.expand("../../../docs", __DIR__)

  @docs %{
    "tutorial" => %{
      title: "End-to-end tutorial",
      file: "tutorial.md"
    }
  }

  for {_slug, %{file: file}} <- @docs do
    @external_resource Path.join(@docs_dir, file)
  end

  @rendered Map.new(@docs, fn {slug, %{title: title, file: file}} ->
              path = Path.join(@docs_dir, file)
              source = File.read!(path)
              {slug, %{title: title, html: Markdown.to_html(source)}}
            end)

  @impl true
  def mount(params, _session, socket) do
    slug = Map.get(params, "slug", "tutorial")

    case Map.fetch(@rendered, slug) do
      {:ok, doc} ->
        {:ok,
         socket
         |> assign(:slug, slug)
         |> assign(:doc, doc)
         |> assign(:other_docs, other_docs(slug))
         |> assign(:not_found, false)}

      :error ->
        {:ok,
         socket
         |> assign(:slug, slug)
         |> assign(:not_found, true)
         |> assign(:other_docs, other_docs(nil))}
    end
  end

  defp other_docs(current_slug) do
    @rendered
    |> Enum.reject(fn {slug, _} -> slug == current_slug end)
    |> Enum.map(fn {slug, %{title: title}} -> %{slug: slug, title: title} end)
    |> Enum.sort_by(& &1.title)
  end

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 class="text-2xl">Doc not found</h1>
      <p class="text-sm opacity-70">
        No doc registered under <code>{@slug}</code>.
      </p>
      <p class="mt-4">
        <.link navigate={~p"/recruiter/docs"} class="link link-primary">
          ← Tutorial
        </.link>
      </p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-4" id={"doc-" <> @slug}>
        <p class="text-xs">
          <.link navigate={~p"/recruiter/sessions"} class="link">
            ← Back to sessions
          </.link>
        </p>

        <article class="prose prose-sm max-w-none space-y-3">
          {@doc.html}
        </article>

        <footer :if={@other_docs != []} class="pt-6 border-t border-base-300 text-sm">
          <p class="opacity-70 mb-2">Other docs:</p>
          <ul class="list-disc pl-6">
            <li :for={d <- @other_docs}>
              <.link navigate={~p"/recruiter/docs/#{d.slug}"} class="link">
                {d.title}
              </.link>
            </li>
          </ul>
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
