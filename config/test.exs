import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :interview, Interview.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "interview_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :interview, InterviewWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "uh9V7qxizVe9+L4pIJ4yXyygxXz0Ts0gwQJweNiZcWozGD+Lku9APDA6kkXAhmf2",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Inline the async `last_used_at` touch under tests so the SQL sandbox
# owner sees the write and we don't get owner-exited noise from a
# detached Task. See `Interview.Auth.ApiKeys.touch_used_async/1`.
config :interview, :async_touch?, false

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban — manual mode in tests so jobs only run when explicitly drained.
config :interview, Oban, testing: :manual

# Webhook HTTP client — process-local stub so tests can program responses
# and assert on POST bodies/headers (PLAN §3.1, §7 Phase 4).
config :interview, Interview.Webhooks.HTTP, adapter: Interview.WebhookStub

# Whisper transcripts — process-local stub. `enabled: true` so the
# end-to-end path (mark_ready → enqueue → worker → set_transcript) is
# exercised in CI; production keeps `enabled: false` by default and
# flips via runtime.exs when OPENAI_API_KEY is present.
config :interview, Interview.Transcripts,
  enabled: true,
  adapter: Interview.TranscriptsStub

# Webhook URL policy — tests routinely use `https://example.test/hook`
# (passes shape) and the stub bypasses the destination check entirely.
# URLPolicy tests that *want* to exercise the strict path pass explicit
# opts. Default to the strict policy here so prod-shaped configs are
# exercised in CI.
config :interview, Interview.Webhooks,
  allow_http_urls: false,
  allow_private_destinations: false

# Storage — write into a per-run tempdir so tests can't fight each other.
config :interview, Interview.Storage,
  adapter: Interview.Storage.Local,
  root:
    Path.join(System.tmp_dir!(), "interview_test_uploads_#{System.unique_integer([:positive])}")
