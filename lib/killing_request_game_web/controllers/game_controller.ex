defmodule KillingRequestGameWeb.GameController do
  use KillingRequestGameWeb, :controller
  alias Phoenix.PubSub
  alias KillingRequestGame.RedisSession

  def index(conn, params) do
    conn = case {params["player_id"], params["player_name"]} do
      {player_id, player_name} when not is_nil(player_id) and not is_nil(player_name) ->
        # Set session data from query parameters
        conn
        |> put_session(:player_id, player_id)
        |> put_session(:player_name, player_name)
      _ ->
        # Set default player_id if not already set
        case get_session(conn, :player_id) do
          nil ->
            player_id = "player-#{System.unique_integer([:positive])}"
            conn
            |> put_session(:player_id, player_id)
          _ ->
            conn
        end
    end

    redirect(conn, to: ~p"/")
  end

  def set_player(conn, %{"player_id" => player_id, "player_name" => player_name}) do
    conn
    |> put_session(:player_id, player_id)
    |> put_session(:player_name, player_name)
    |> redirect(to: ~p"/")
  end

  def flush_session(conn, _params) do
    KillingRequestGame.RedisSession.reset_game()

    json(conn, %{success: true})
  end

  def clear_session(conn, _params) do
    conn
    |> put_session(:player_id, nil)
    |> put_session(:player_name, nil)
    |> redirect(to: ~p"/")
  end

  def start_game(conn, _params) do
    assassin = RedisSession.get_players()
    |> Map.keys()
    |> Enum.random()

    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:game_started, assassin})
    RedisSession.start_game(assassin)

    conn
    |> json(%{success: true})
  end
end
