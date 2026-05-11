defmodule InterviewWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use InterviewWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-base-content/10">
      <div class="mx-auto max-w-5xl px-6 sm:px-10 h-16 flex items-center justify-between gap-6">
        <.link navigate="/" class="group flex items-baseline gap-3 -ml-0.5">
          <span class="font-display text-[1.35rem] leading-none tracking-[-0.015em]">
            Interview
          </span>
          <span class="zen-eyebrow hidden sm:inline-block translate-y-[-1px] transition-opacity duration-500 group-hover:opacity-60">
            — a quiet studio
          </span>
        </.link>

        <nav class="flex items-center gap-1 sm:gap-2">
          <%= if @current_scope do %>
            <.nav_link navigate={~p"/recruiter/sessions"}>Sessions</.nav_link>
            <.nav_link navigate={~p"/recruiter/templates"}>Templates</.nav_link>
            <.nav_link navigate={~p"/recruiter/docs"}>Tutorial</.nav_link>
            <span class="hidden md:inline-block mx-3 h-3 w-px bg-base-content/15" aria-hidden="true"></span>
            <span class="zen-eyebrow hidden md:inline-block normal-case tracking-[0.08em] text-[10.5px] truncate max-w-[14rem]">
              {@current_scope.recruiter.email}
            </span>
            <.theme_toggle />
            <.link
              href={~p"/auth/sign-out"}
              method="delete"
              class="px-3 py-1.5 text-[13px] tracking-tight opacity-60 hover:opacity-100 transition-opacity duration-300"
            >
              Sign out
            </.link>
          <% else %>
            <.theme_toggle />
            <.link
              href={~p"/auth/sign-in"}
              class="ml-2 px-4 py-1.5 text-[13px] tracking-tight border border-base-content/80 hover:bg-base-content hover:text-base-100 transition-colors duration-300"
            >
              Sign in
            </.link>
          <% end %>
        </nav>
      </div>
    </header>

    <main class="px-6 sm:px-10 py-16 sm:py-24">
      <div class="mx-auto max-w-2xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <footer class="px-6 sm:px-10 pb-10 mt-auto">
      <div class="mx-auto max-w-2xl flex items-center justify-between zen-eyebrow opacity-50">
        <span>§ {Calendar.strftime(Date.utc_today(), "%Y")}</span>
        <span>Interview · async studio</span>
      </div>
    </footer>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="px-3 py-1.5 text-[13px] tracking-tight opacity-70 hover:opacity-100 transition-opacity duration-300"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="group"
      aria-label="Theme"
      class="relative ml-2 hidden sm:inline-flex items-center border border-base-content/15 rounded-full p-[2px]"
    >
      <span
        aria-hidden="true"
        class="absolute top-[2px] bottom-[2px] w-[calc(33.333%-1px)] rounded-full bg-base-content/8 left-[2px] [[data-theme=light]_&]:left-[calc(33.333%+1px)] [[data-theme=dark]_&]:left-[calc(66.666%-1px)] transition-[left] duration-500 ease-[cubic-bezier(0.22,1,0.36,1)]"
      >
      </span>

      <button
        type="button"
        aria-label="System theme"
        class="relative z-10 flex items-center justify-center w-7 h-7 cursor-pointer opacity-60 hover:opacity-100 transition-opacity duration-300"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-[14px]" />
      </button>

      <button
        type="button"
        aria-label="Light theme"
        class="relative z-10 flex items-center justify-center w-7 h-7 cursor-pointer opacity-60 hover:opacity-100 transition-opacity duration-300"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-[14px]" />
      </button>

      <button
        type="button"
        aria-label="Dark theme"
        class="relative z-10 flex items-center justify-center w-7 h-7 cursor-pointer opacity-60 hover:opacity-100 transition-opacity duration-300"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-[14px]" />
      </button>
    </div>
    """
  end
end
