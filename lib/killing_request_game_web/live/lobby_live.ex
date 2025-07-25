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
      |> assign(:form_answers, %{})
      |> assign(:successful_requests, RedisSession.get_successful_requests())
      |> assign(:killed_requests, RedisSession.get_killed_requests())
      |> assign(:vote_requests, RedisSession.get_vote_requests())
      |> assign(:vote_results, %{})
      |> assign(:request_form, %{url: "", method: "GET", body: "", params: "", raw_request: ""})
      |> assign(:selected_raw_response, nil)
      |> assign(:cooldown, false)}
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
        |> assign(:request_form, socket.assigns.request_form)
        |> assign(:successful_requests, converted_state.successful_requests)
        |> assign(:killed_requests, converted_state.killed_requests)
        |> assign(:vote_requests, converted_state.vote_requests)
        |> assign(:vote_results, converted_state.vote_results)

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

    {:noreply, assign(socket, players: updated_players, request_form: socket.assigns.request_form)}
  end

  def handle_info({:player_removed, id}, socket) do
    players = Map.delete(socket.assigns.players, id)

    {:noreply, assign(socket, players: players)}
  end

  def handle_info({:game_started, assassin}, socket) do
    {:noreply, assign(socket, phase: :questions, assassin: assassin)}
  end

  def handle_info({:game_ended}, socket) do
    {:noreply, assign(socket, phase: :end)}
  end

  def handle_info({:assassin_questions_finished}, socket) do
    RedisSession.set_phase(:game)
    {:noreply, assign(socket, phase: :game)}
  end

  def handle_info({:request_result, log, player_id}, socket) do
    if player_id == socket.assigns.id do
      {:noreply, socket }
    else
      successful_requests = RedisSession.get_successful_requests()

      {:noreply, assign(socket, logs: [log | socket.assigns.logs], successful_requests: successful_requests)}
    end
  end

  def handle_info({:log_added, log, player_id}, socket) do
    if player_id == socket.assigns.id do
      {:noreply, socket}
    else
      {:noreply, assign(socket, logs: [log | socket.assigns.logs])}
    end
  end

  def handle_info({:killed_request}, socket) do
    {:noreply, assign(socket, killed_requests: RedisSession.get_killed_requests())}
  end

  def handle_info({:request_vote_updated, vote_requests}, socket) do
    {:noreply, assign(socket, vote_requests: vote_requests)}
  end

  def handle_info({:request_vote}, socket) do
    {:noreply, assign(socket, phase: :report)}
  end

  def handle_info({:voting_finished}, socket) do
    {:noreply, assign(socket, phase: :game, vote_requests: [], vote_results: %{}, cooldown: false)}
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

      {:noreply, assign(socket, id: id, request_form: socket.assigns.request_form)}
    else
      {:noreply, socket}
    end
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
    RedisSession.save_clues(params)

    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:assassin_questions_finished})

    {:noreply, assign(socket, phase: :game)}
  end

  def handle_event("update_answer", %{"index" => index, "value" => value}, socket) do
    form_answers = Map.put(socket.assigns.form_answers, index, value)
    {:noreply, assign(socket, form_answers: form_answers)}
  end

  def handle_event("update_request_form", %{"field" => field, "value" => value}, socket) do
    request_form = Map.put(socket.assigns.request_form, String.to_atom(field), value)
    {:noreply, assign(socket, request_form: request_form)}
  end

  # -----------------------------------------------------------------------------------------------
  # API Requests
  # -----------------------------------------------------------------------------------------------

  def handle_event("submit_request", %{"url" => url, "method" => method, "body" => body, "params" => params}, socket) do
    player_id = socket.assigns.id

    # Log the request submission
    log = %{
      player: player_id,
      action: "Processando 🕛 5s",
      request: "#{method} #{url}",
      raw_response: nil,
      response_size: nil
    }

    RedisSession.add_log(log)
    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:log_added, log, player_id})

    {:noreply,
     socket
     |> assign(logs: [log | socket.assigns.logs], cooldown: true)
     |> push_event("make_delayed_request", %{
       url: url,
       method: method,
       body: body,
       params: params,
       player_id: player_id,
       delay: 5000
     })}
  end

  def handle_event("block_player_request", %{"target_player_id" => target_player_id}, socket) do
    if socket.assigns.id == socket.assigns.assassin do
      # Block the request
      RedisSession.block_player_request(target_player_id)
      logs = [%{
        player: socket.assigns.id,
        action: "KILLED ☠️",
        request: "blocked #{target_player_id}",
        raw_response: nil,
        response_size: nil
      } | socket.assigns.logs]
      {:noreply, assign(socket, logs: logs)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_result", %{"error" => error, "method" => method, "status" => status, "success" => false, "url" => url, "player" => player_request_id}, socket) do
    logs = [%{player: player_request_id, action: "Falha 🤔 #{status}", request: "#{method} #{url} (#{error})", raw_response: nil, response_size: nil} | socket.assigns.logs]

    {:noreply, assign(socket, logs: logs, cooldown: false)}
  end

  def handle_event("request_result_blocked", data, socket) do
    clues = RedisSession.get_clues()
    clue_strings = for i <- 0..7 do
      question = clues["q#{i}"]
      answer = clues["a#{i}"]
      "#{question} #{answer}"
    end

    # Pick a random clue
    random_clue = Enum.random(clue_strings)

    raw_response = %{
      method: data["method"],
      url: data["url"],
      status: data["status"],
      headers: %{"X-Clue" => random_clue},
      body: nil,
      size: nil,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    log = %{
      player: data["player"],
      action: "KILLED 🔪",
      request: data["url"],
      raw_response: raw_response,
      response_size: nil,
      success: false,
      status: 500,
      error: "Request blocked by assassin"
    }

    RedisSession.add_log(log)
    RedisSession.increment_killed_requests(data["player"])
    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:killed_request})

    if length(RedisSession.get_killed_requests()) >= 20 do
      Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:game_ended})
    end

    {:noreply, assign(socket, logs: [log | socket.assigns.logs], cooldown: false)}
  end

  def handle_event("request_result", %{
    "success" => success,
    "method" => method,
    "url" => url,
    "status" => status,
    "error" => error,
    "response_headers" => headers,
    "response_body" => body,
    "response_size" => size,
    "player" => player_request_id
  }, socket) do
    player_id = socket.assigns.id

    # Create raw response data
    raw_response = %{
      method: method,
      url: url,
      status: status,
      headers: headers,
      body: body,
      size: size,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    raw_response = if player_request_id == player_id, do: raw_response, else: nil

    log = if success do
      RedisSession.increment_successful_requests(player_id)

      %{player: player_id,
        action: "Ufa! Tudo Limpo ✅",
        request: "#{method} #{url} (#{status})",
        response_size: size, raw_response: raw_response}
    else
      %{player: player_id, action: "Falha 🤔", request: "#{method} #{url} (#{error})", raw_response: raw_response, response_size: nil}
    end

    RedisSession.add_log(log)

    successful_requests = RedisSession.get_successful_requests()
    Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:request_result, log, player_request_id})

    if length(successful_requests) >= 40 do
      Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:game_ended})
    end

    {:noreply, assign(socket, logs: [log | socket.assigns.logs], successful_requests: successful_requests, cooldown: false)}
  end

  def handle_event("show_raw_response", %{"log-index" => log_index}, socket) do
    log_index = String.to_integer(log_index)
    selected_log = Enum.at(socket.assigns.logs, log_index)

    if selected_log && selected_log.raw_response do
      {:noreply, assign(socket, selected_raw_response: selected_log.raw_response)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_vote", _params, socket) do
    player_id = socket.assigns.id
    vote_requests = RedisSession.get_vote_requests()

    # Prevent duplicate vote requests
    if player_id in vote_requests do
      {:noreply, socket}
    else
      # Add vote request
      RedisSession.add_vote_request(player_id)
      vote_requests = RedisSession.get_vote_requests()
      Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:request_vote_updated, vote_requests})

      # Check if we have enough vote requests (threshold = 2)
      if length(vote_requests) >= 2 do
        RedisSession.set_phase(:report)
        Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:request_vote})
      end

      {:noreply, assign(socket, vote_requests: vote_requests)}
    end
  end

  def handle_event("vote_player", %{"target_id" => target_id}, socket) do
    voter_id = socket.assigns.id
    target_player = Map.get(socket.assigns.players, target_id)
    vote_results = RedisSession.get_vote_results()

    # Prevent duplicate votes
    if Map.has_key?(vote_results, voter_id) do
      {:noreply, assign(socket, vote_results: vote_results)}
    else
      if target_player do
        # Add vote to results
        RedisSession.add_vote(target_id, voter_id)
        updated_vote_results = RedisSession.get_vote_results()

        # Check if all players have voted
        total_votes = map_size(updated_vote_results)
        total_players = map_size(socket.assigns.players)

        if total_votes >= total_players do
          # Tally votes: count how many votes each target received
          tally = Enum.reduce(updated_vote_results, %{}, fn {_voter, target}, acc ->
            Map.update(acc, target, 1, &(&1 + 1))
          end)
          {most_voted_player, _vote_count} = Enum.max_by(tally, fn {_player_id, count} -> count end, fn -> {nil, 0} end)

          if most_voted_player == socket.assigns.assassin do
            # Correct vote - assassino foi descoberto!
            most_voted_player_data = Map.get(socket.assigns.players, most_voted_player)
            victory_log = %{
              player: "SYSTEM",
              action: "ASSASSINO DESCOBERTO! 🎉",
              request: "#{most_voted_player_data.name} é o assassino!",
              raw_response: nil,
              response_size: nil
            }

            RedisSession.add_log(victory_log)
            Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:game_ended})
            Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:log_added, victory_log, "SYSTEM"})
          else
            defeat_log = %{
              player: "SYSTEM",
              action: "VOTO ERRADO! ☠️",
              request: "O assassino continua livre! Jogo continua...",
              raw_response: nil,
              response_size: nil
            }

            RedisSession.add_log(defeat_log)
            Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:log_added, defeat_log, "SYSTEM"})

            # Reset voting and continue game
            RedisSession.clear_vote_requests()
            RedisSession.clear_vote_results()
            RedisSession.set_phase(:game)
            Phoenix.PubSub.broadcast(KillingRequestGame.PubSub, "game:lobby", {:voting_finished})
          end
        end

        {:noreply, assign(socket, vote_results: updated_vote_results)}
      else
        {:noreply, assign(socket, vote_results: vote_results)}
      end
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

  # Helper function to get HTTP status text
  defp get_status_text(status) do
    case status do
      200 -> "OK"
      201 -> "Created"
      204 -> "No Content"
      400 -> "Bad Request"
      401 -> "Unauthorized"
      403 -> "Forbidden"
      404 -> "Not Found"
      500 -> "Internal Server Error"
      502 -> "Bad Gateway"
      503 -> "Service Unavailable"
      _ -> "Unknown"
    end
  end

  # Helper function to truncate response body
  defp truncate_response(body) when is_binary(body) do
    if String.length(body) > 500 do
      String.slice(body, 0, 500) <> "\n... (truncated)"
    else
      body
    end
  end
  defp truncate_response(_), do: "No body"

  # Helper function to format response body with JSON syntax highlighting
  defp format_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json_data} ->
        # Format JSON with proper indentation
        formatted_json = Jason.encode!(json_data, pretty: true)
        # Convert to HTML with syntax highlighting
        formatted_json
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;")
        |> String.replace("\"", "<span class=\"text-green-400\">\"</span>")
        |> String.replace(":", "<span class=\"text-yellow-400\">:</span>")
        |> String.replace("{", "<span class=\"text-blue-400\">{</span>")
        |> String.replace("}", "<span class=\"text-blue-400\">}</span>")
        |> String.replace("[", "<span class=\"text-purple-400\">[</span>")
        |> String.replace("]", "<span class=\"text-purple-400\">]</span>")
        |> String.replace(",", "<span class=\"text-gray-400\">,</span>")
        |> String.replace("\n", "<br>")
        |> String.replace("  ", "&nbsp;&nbsp;")
        |> Phoenix.HTML.raw()
      _ ->
        # Not JSON, return as plain text
        body
        |> String.replace("&", "&amp;")
        |> String.replace("<", "&lt;")
        |> String.replace(">", "&gt;")
        |> String.replace("\n", "<br>")
        |> Phoenix.HTML.raw()
    end
  end
  defp format_response_body(_), do: Phoenix.HTML.raw("No body")

  # Helper function to format headers for display
  defp format_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {key, value} -> %{key: key, value: value} end)
  end
  defp format_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(fn {key, value} -> %{key: key, value: value} end)
  end
  defp format_headers(_), do: []
end
