# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :interview,
  ecto_repos: [Interview.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :interview, InterviewWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: InterviewWeb.ErrorHTML, json: InterviewWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Interview.PubSub,
  live_view: [signing_salt: "rOmmYuV2"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  interview: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # @you/interview-embed — customer-facing SDK bundle (PLAN §3.1, §7 Phase 3).
  # Lives at /embed.v1.js so paste-in <script src="https://cdn…/embed.v1.js"> works.
  # Single-file IIFE, no deps, target ES2017 for the broadest desktop reach.
  embed: [
    args:
      ~w(embed/index.js --bundle --target=es2017 --format=iife --outfile=../priv/static/embed.v1.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  interview: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Oban — embedded in the web nodes for v1 (PLAN §12.7).
# Polling notifier (Oban.Notifiers.Postgres polling mode) is what we want
# over Neon's transaction-mode pooler (PLAN §12.5).
config :interview, Oban,
  repo: Interview.Repo,
  notifier: Oban.Notifiers.Postgres,
  queues: [
    finalize: 1,
    sweeper: 1,
    webhook: 5,
    transcript: 2,
    scoring: 2
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Interview.Workers.AbandonedSessionSweeper},
       {"*/5 * * * *", Interview.Workers.AbandonedPromptAssetSweeper},
       {"0 3 * * *", Interview.Workers.RetentionSweeper},
       {"30 3 * * *", Interview.Workers.WebhookDeliveriesPrune},
       {"0 4 * * *", Interview.Workers.AuditPrune}
     ]}
  ]

# Storage adapter (PLAN decision #3 / decision #4). Local filesystem for dev;
# Tigris/S3 lands when we deploy. The behaviour is in `Interview.Storage`.
config :interview, Interview.Storage,
  adapter: Interview.Storage.Local,
  root: "priv/uploads"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
