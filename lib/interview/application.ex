defmodule Interview.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InterviewWeb.Telemetry,
      Interview.Repo,
      {DNSCluster, query: Application.get_env(:interview, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Interview.PubSub},
      {Task.Supervisor, name: Interview.TaskSupervisor},
      {Oban, Application.fetch_env!(:interview, Oban)},
      InterviewWeb.Endpoint
    ]

    children =
      if Application.get_env(:interview, :harness_enabled, false) and
           Phoenix.Endpoint.server?(:interview, InterviewWeb.Endpoint) do
        children ++
          [
            {Bandit,
             plug: InterviewWeb.HarnessRouter,
             scheme: :http,
             ip: {127, 0, 0, 1},
             port: Application.get_env(:interview, :harness_port, 5174)}
          ]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Interview.Supervisor]
    result = Supervisor.start_link(children, opts)
    Interview.SoakTelemetry.attach()
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InterviewWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
