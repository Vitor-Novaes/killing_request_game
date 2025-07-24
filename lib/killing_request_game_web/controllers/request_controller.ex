defmodule KillingRequestGameWeb.RequestController do
  use KillingRequestGameWeb, :controller
  alias Phoenix.PubSub
  alias KillingRequestGame.RedisSession
  alias Finch

  def make_request(conn, %{"url" => url, "method" => method, "body" => body, "player_id" => player_id}) do
    # Check if the request is being blocked by assassin
    case check_if_blocked(player_id) do
      {:blocked, assassin_id} ->
        # Request was blocked by assassin
        RedisSession.add_log(%{
          "player" => assassin_id,
          "action" => "blocked",
          "request" => "request from #{player_id}"
        })

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Request blocked by assassin", status: 500})

      :not_blocked ->
        # Process the request after 5 second delay
        Task.async(fn ->
          Process.sleep(5000) # 5 second delay
          execute_request(url, method, body, player_id)
        end)

        conn
        |> json(%{success: true, message: "Request queued, will execute in 5 seconds"})
    end
  end

  def block_request(conn, %{"target_player_id" => target_player_id, "assassin_id" => assassin_id}) do
    # Verify the player is actually the assassin
    case RedisSession.get_game_controller() do
      {:ok, game_state} ->
        if game_state["assassin"] == assassin_id do
          # Block the request
          RedisSession.block_player_request(target_player_id)

          conn
          |> json(%{success: true, message: "Request blocked"})
        else
          conn
          |> put_status(403)
          |> json(%{success: false, error: "Not authorized"})
        end
      _ ->
        conn
        |> put_status(500)
        |> json(%{success: false, error: "Game state not found"})
    end
  end

  def check_blocked(conn, %{"player_id" => player_id}) do
    case check_if_blocked(player_id) do
      {:blocked, assassin_id} ->
        # Clear the blocked request after checking
        RedisSession.clear_blocked_request(player_id)
        conn
        |> json(%{blocked: true, assassin_id: assassin_id})
      :not_blocked ->
        conn
        |> json(%{blocked: false})
    end
  end

  def test_endpoint(conn, _params) do
    conn
    |> json(%{
      success: true,
      message: "Test endpoint working!",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{
        test: "This is a test response",
        random_number: :rand.uniform(1000)
      }
    })
  end

  defp check_if_blocked(player_id) do
    case RedisSession.get_blocked_requests() do
      {:ok, blocked_requests} ->
        if Map.has_key?(blocked_requests, player_id) do
          {:blocked, blocked_requests[player_id]}
        else
          :not_blocked
        end
      _ ->
        :not_blocked
    end
  end

  defp execute_request(url, method, body, player_id) do
    try do
      # Prepare the request
      headers = [{"content-type", "application/json"}]

      request = case method do
        "GET" -> {String.to_charlist(url), headers}
        "POST" -> {String.to_charlist(url), headers, "application/json", body}
        "PUT" -> {String.to_charlist(url), headers, "application/json", body}
        "DELETE" -> {String.to_charlist(url), headers}
        _ -> {String.to_charlist(url), headers}
      end

      # Make the request
      case Finch.build(method, url, headers, body) |> Finch.request(KillingRequestGame.Finch) do
        {:ok, %Finch.Response{status: status, body: response_body}} ->
          # Request successful
          RedisSession.increment_successful_requests(player_id)
          RedisSession.add_log(%{
            "player" => player_id,
            "action" => "successful_request",
            "request" => "#{method} #{url} (#{status})"
          })

          # Broadcast success to all players
          Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby",
            {:request_success, player_id, method, url, status})

        {:error, error} ->
          # Request failed
          RedisSession.add_log(%{
            "player" => player_id,
            "action" => "failed_request",
            "request" => "#{method} #{url} (#{inspect(error)})"
          })

          # Broadcast failure to all players
          Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby",
            {:request_failed, player_id, method, url, inspect(error)})
      end
    rescue
      error ->
        # Handle any other errors
        RedisSession.add_log(%{
          "player" => player_id,
          "action" => "request_error",
          "request" => "#{method} #{url} (#{inspect(error)})"
        })

        Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby",
          {:request_error, player_id, method, url, inspect(error)})
    end
  end
end
