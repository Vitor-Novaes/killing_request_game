defmodule KillingRequestGameWeb.LobbyLive do
  use KillingRequestGameWeb, :live_view

  alias Phoenix.PubSub
  alias KillingRequestGame.RedisSession

  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(KillingRequestGame.PubSub, "game:lobby")

    player_id = get_player_id_from_session(session)
    player_name = session["player_name"]

    # Load game state from Redis controller
    game_state = case RedisSession.get_game_controller() do
      {:ok, state} -> RedisSession.convert_to_liveview_format(state)
      {:error, :not_found} ->
        # Initialize new game state
        {:ok, default_state} = RedisSession.reset_game()
        RedisSession.convert_to_liveview_format(default_state)
    end

    {:ok,
     socket
     |> assign(:page_title, "Killing Request Game")
     |> assign(:players, game_state.players)
     |> assign(:requests, game_state.requests)
     |> assign(:assassin, game_state.assassin)
     |> assign(:logs, game_state.logs)
     |> assign(:clues, game_state.clues)
     |> assign(:hints, game_state.hints)
     |> assign(:phase, game_state.phase)
     |> assign(:id, player_id)
     |> assign(:name, player_name)
     |> assign(:form_answers, %{})}
  end

  def handle_info(:tick, socket) do
    case RedisSession.get_game_controller() do
      {:ok, game_state} ->
        converted_state = RedisSession.convert_to_liveview_format(game_state)
        socket = socket
        |> assign(:players, converted_state.players)
        |> assign(:requests, converted_state.requests)
        |> assign(:assassin, converted_state.assassin)
        |> assign(:logs, converted_state.logs)
        |> assign(:hints, converted_state.hints)
        |> assign(:phase, converted_state.phase)
        |> assign(:clues, converted_state.clues)

        {:noreply, socket}
      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:player_joined, player}, socket) do
    players = Map.put(socket.assigns.players, player.id, player)
    {:noreply, assign(socket, players: players)}
  end

  def handle_info({:player_moved, %{id: id, x: x, y: y}}, socket) do
    updated_players =
      Map.update(socket.assigns.players, id, nil, fn p ->
        %{p | x: x, y: y}
      end)

    {:noreply, assign(socket, players: updated_players)}
  end

  def handle_info({:player_removed, id}, socket) do
    players = Map.delete(socket.assigns.players, id)

    {:noreply, assign(socket, players: players)}
  end

  def handle_info({:game_started, assassin}, socket) do
    {:noreply, assign(socket, phase: :questions, assassin: assassin)}
  end

  def handle_info({:assassin_questions_finished}, socket) do
    {:noreply, assign(socket, phase: :game)}
  end

  def handle_event("register", %{"name" => name}, socket) do
    id = socket.assigns.id
    player = %{id: id, name: name, x: 0, y: 0, role: nil}

    # Add player to Redis controller (convert to Redis format)
    redis_player = %{"id" => id, "name" => name, "x" => 0, "y" => 0, "role" => nil}
    RedisSession.add_player(redis_player)

    # Update local state
    players = Map.put(socket.assigns.players, id, player)
    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:player_joined, player})

    # Redirect to set session data and return to lobby
    {:noreply,
     socket
     |> assign(players: players, id: id, name: name)
     |> redirect(to: ~p"/controller/set_player?player_id=#{id}&player_name=#{name}")}
  end

  def handle_event("move", %{"x" => x, "y" => y}, socket) do
    id = socket.assigns.id
    if id != nil and Map.has_key?(socket.assigns.players, id) do
      Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:player_moved, %{id: id, x: x, y: y}})

      {:noreply, assign(socket, id: id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("click_request", %{"request_id" => id, "player_id" => pid}, socket) do
    logs = [%{player: pid, action: "clicked", request: id} | socket.assigns.logs]
    {requests, hints} = {socket.assigns.requests, socket.assigns.hints}

    {:noreply, assign(socket, logs: logs, requests: requests, hints: hints)}
  end

  def handle_event("clear_session", _params, socket) do
    id = socket.assigns.id
    RedisSession.remove_player(id)

    players = Map.delete(socket.assigns.players, id)
    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:player_removed, id})

    {:noreply,
     socket
     |> assign(id: nil, name: nil, players: players)
     |> redirect(to: ~p"/controller/clear_session")}
  end

  def handle_event("answer_clue_question", params, socket) do
    IO.inspect(params)
    RedisSession.save_clues(params)

    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:assassin_questions_finished})

    {:noreply, assign(socket, phase: :game)}
  end

  def handle_event("update_answer", %{"index" => index, "value" => value}, socket) do
    form_answers = Map.put(socket.assigns.form_answers, index, value)
    {:noreply, assign(socket, form_answers: form_answers)}
  end

  def handle_event("kill_request", %{"request_id" => rid, "player_id" => pid}, socket) do
    if pid == socket.assigns.assassin do
      reqs = Map.update!(socket.assigns.requests, String.to_integer(rid), fn req -> Map.put(req, :status, 500) end)
      hints = Enum.random(socket.assigns.clues)
      logs = [%{player: pid, action: "killed", request: rid} | socket.assigns.logs]
      {:noreply, assign(socket, logs: logs, requests: reqs, hints: hints)}
    else
      {:noreply, socket}
    end
  end

  # Helper function to get or generate player ID from session
  defp get_player_id_from_session(session) do
    case session["player_id"] do
      nil ->
        # Generate new player ID if none exists
        "player-#{System.unique_integer([:positive])}"
      player_id ->
        player_id
    end
  end
end
