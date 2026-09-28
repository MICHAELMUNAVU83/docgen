defmodule Docgen.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:docgen, :check_system_tools, true) do
      Docgen.SystemCheck.log_warnings()
    end

    children = [
      DocgenWeb.Telemetry,
      Docgen.Repo,
      {DNSCluster, query: Application.get_env(:docgen, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Docgen.PubSub},
      Docgen.Convert.Limiter,
      Docgen.Store,
      Docgen.Janitor,
      # Start to serve requests, typically the last entry
      DocgenWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Docgen.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DocgenWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
