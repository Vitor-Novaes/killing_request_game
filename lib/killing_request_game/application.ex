defmodule KillingRequestGame.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KillingRequestGameWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:killing_request_game, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KillingRequestGame.PubSub},
      # Start Redis connection
      {Redix, host: "localhost", port: 6379, name: :redix},
      # Start the Finch HTTP client for sending emails
      {Finch, name: KillingRequestGame.Finch},
      # Start a worker by calling: KillingRequestGame.Worker.start_link(arg)
      # {KillingRequestGame.Worker, arg},
      # Start to serve requests, typically the last entry
      KillingRequestGameWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: KillingRequestGame.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KillingRequestGameWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
