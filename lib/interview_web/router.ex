defmodule InterviewWeb.Router do
  use InterviewWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {InterviewWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Pages allowed to be embedded in cross-origin iframes
  # (the candidate recorder). See PLAN §4.4.
  pipeline :embed do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {InterviewWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug InterviewWeb.Plugs.EmbedCSP
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :recruiter_api do
    plug :accepts, ["json", "yaml", "markdown"]
    plug InterviewWeb.Plugs.TenantAuth
  end

  pipeline :tenant_api do
    plug :accepts, ["json"]
    plug InterviewWeb.Plugs.TenantAuth
  end

  pipeline :recruiter_only do
    plug :accepts, ["json"]
    plug :fetch_session
    plug InterviewWeb.Plugs.RecruiterAuth
  end

  # Recruiter-authenticated browser routes that serve binary content
  # (e.g. playback of MP4 artifacts). No `accepts` filter so we can
  # respond with `video/mp4` regardless of the browser's Accept header.
  pipeline :recruiter_browser do
    plug :fetch_session
    plug InterviewWeb.Plugs.RecruiterAuth
  end

  # Recruiter-authenticated form POSTs (multipart). Cookie session + CSRF
  # required — these handle multipart file uploads from the recruiter
  # dashboard.
  pipeline :recruiter_form do
    plug :accepts, ["html", "json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug InterviewWeb.Plugs.RecruiterAuth
  end

  scope "/", InterviewWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/capture/new", CaptureSessionController, :new

    get "/auth/sign-in", AuthController, :sign_in
    post "/auth/sign-in", AuthController, :request_link_form
    get "/auth/magic-link/:token", MagicLinkController, :consume
    delete "/auth/sign-out", AuthController, :sign_out

    live_session :recruiter, on_mount: [{InterviewWeb.UserAuth, :ensure_recruiter}] do
      live "/recruiter/templates", RecruiterTemplatesLive, :index
      live "/recruiter/templates/:id", RecruiterTemplateLive
      live "/recruiter/templates/:tid/questions/:qid/prompt", RecruiterPromptRecorderLive
      live "/recruiter/sessions", RecruiterSessionsLive, :index
      live "/recruiter/sessions/:id", RecruiterSessionLive, :show
      live "/recruiter/settings", RecruiterSettingsLive, :index
      live "/recruiter/docs", DocsLive, :index
      live "/recruiter/docs/:slug", DocsLive, :show
    end
  end

  scope "/", InterviewWeb do
    pipe_through :recruiter_browser

    get "/recruiter/playback/:response_id", PlaybackController, :show
  end

  scope "/", InterviewWeb do
    pipe_through :recruiter_form

    post "/recruiter/templates/:tid/questions/:qid/attachment",
         PromptAssetAttachmentController,
         :create
  end

  scope "/api/auth", InterviewWeb do
    pipe_through :api

    post "/magic-links", MagicLinkController, :request
  end

  scope "/api/auth", InterviewWeb do
    pipe_through :recruiter_only

    post "/refresh", AuthController, :refresh
  end

  scope "/api/tenant", InterviewWeb do
    pipe_through :recruiter_only

    get "/api-keys", ApiKeyController, :index
    post "/api-keys", ApiKeyController, :create
    delete "/api-keys/:id", ApiKeyController, :revoke
  end

  scope "/", InterviewWeb do
    pipe_through :embed

    live "/capture/:session_id", CaptureLive
  end

  scope "/sessions", InterviewWeb do
    pipe_through :api

    post "/:session_id/responses/:response_id/capture_complete",
         CaptureCompleteController,
         :create
  end

  # Candidate-accessible prompt asset playback (PLAN §3.4 R5). The
  # session_id in the URL is the bearer — asset must be referenced by
  # the session's frozen template_version. No pipeline → no Accept
  # filter, so we can serve video/image/pdf.
  scope "/capture", InterviewWeb do
    get "/:session_id/prompt_assets/:asset_id", PromptAssetPlaybackController, :show
  end

  scope "/api/prompt_assets", InterviewWeb do
    pipe_through :api

    post "/:id/capture_complete", PromptAssetCaptureCompleteController, :create
  end

  scope "/api", InterviewWeb do
    pipe_through :recruiter_api

    get "/templates", TemplateController, :index
    post "/templates", TemplateController, :create
    get "/templates/:id", TemplateController, :show
    post "/templates/:id/versions", TemplateController, :create_version
    put "/templates/:id/versions/:vid/questions", TemplateController, :update_questions
    post "/templates/:id/versions/:vid/publish", TemplateController, :publish_version
    post "/templates/:id/import", TemplateController, :import
  end

  scope "/api", InterviewWeb do
    pipe_through :tenant_api

    post "/sessions", SessionController, :create
    post "/sessions/:id/bootstrap", SessionController, :rebootstrap
    delete "/sessions/:id", SessionController, :delete
  end

  # Chrome DevTools probes this URL when DevTools is open. Return 204 so
  # the noisy 404 doesn't fill the logs.
  scope "/" do
    get "/.well-known/appspecific/com.chrome.devtools.json",
        InterviewWeb.PageController,
        :chrome_devtools
  end

  # tus 1.0.0 endpoints. The plug owns the entire URL space under
  # `/uploads/tus`; we forward everything to it (HEAD/PATCH/OPTIONS).
  forward "/uploads/tus", InterviewWeb.Tus.Plug

  # tus 1.0.0 endpoints for recruiter prompt-asset uploads (PLAN §3.4).
  forward "/uploads/prompt_assets", InterviewWeb.Tus.PromptAssetPlug

  # Enable LiveDashboard in development
  if Application.compile_env(:interview, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: InterviewWeb.Telemetry
    end
  end
end
