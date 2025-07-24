// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

Hooks.CursorTracker = {
  mounted() {
    this.handleMouseMove = (e) => {
      // Get viewport dimensions
      const viewportWidth = window.innerWidth
      const viewportHeight = window.innerHeight
      
      // Clamp coordinates to prevent going above screen or beyond viewport
      const clampedX = Math.max(0, Math.min(e.clientX, viewportWidth - 1))
      const clampedY = Math.max(0, Math.min(e.clientY, viewportHeight - 1))
      
      this.pushEvent("move", {
        x: clampedX,
        y: clampedY
      })
    }

    this.lastSent = 0
    this.listener = (e) => {
      const now = Date.now()
      if (now - this.lastSent > 50) {
        this.handleMouseMove(e)
        this.lastSent = now
      }
    }

    window.addEventListener("mousemove", this.listener)
  },
  destroyed() {
    window.removeEventListener("mousemove", this.listener)
  }
}

Hooks.RequestHandler = {
  mounted() {
    this.handleEvent("make_delayed_request", ({url, method, body, params, player_id, delay}) => {
      console.log(`Request queued: ${method} ${url} (${delay}ms delay)`)
      
      setTimeout(() => {
        this.checkIfBlockedAndMakeRequest(url, method, body, params, player_id)
      }, delay)
    })
  },

  updated() {
    // Show raw response container if there's selected data
    const container = document.getElementById('game-area-2')
    if (container && this.el.dataset.selectedRawResponse === 'true') {
      container.style.display = 'block'
    }
  },

  async checkIfBlockedAndMakeRequest(url, method, body, params, player_id) {
    try {
      // Check if request is blocked by making a request to our API
      const checkResponse = await fetch('/api/check_blocked', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ player_id: player_id })
      })

      if (checkResponse.ok) {
        const checkResult = await checkResponse.json()
        if (checkResult.blocked) {
          console.log(`Request blocked by assassin: ${method} ${url}`)
          this.pushEvent("request_result_blocked", {
            success: false,
            method: method,
            url: url,
            status: 500,
            error: "Request blocked by assassin",
            player: player_id,
          })
          return
        }
      }
    } catch (error) {
      console.log("Could not check if blocked, proceeding with request")
    }

    // If not blocked, proceed with the actual request
    this.makeRequest(url, method, body, params, player_id)
  },

  makeRequest(url, method, body, params, player_id) {
    // Build URL with query parameters
    let finalUrl = `<>${url}`
    console.log(finalUrl)
    if (params && params.trim() !== '') {
      try {
        const paramsObj = JSON.parse(params)
        const urlObj = new URL(finalUrl)
        Object.keys(paramsObj).forEach(key => {
          urlObj.searchParams.append(key, paramsObj[key])
        })
        finalUrl = urlObj.toString()
      } catch (error) {
        console.error('Invalid JSON in params:', error)
      }
    }

    const options = {
      method: method,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer '
      },
    }

    if (body && method !== 'GET') {
      options.body = body
    }

    fetch(finalUrl, options)
      .then(async response => {
        console.log(`Request completed: ${method} ${finalUrl} - Status: ${response.status}`)
        
        // Capture raw response data
        const responseText = await response.text()
        const responseHeaders = {}
        response.headers.forEach((value, key) => {
          responseHeaders[key] = value
        })
        
        this.pushEvent("request_result", {
          success: response.ok,
          method: method,
          url: finalUrl,
          status: response.status,
          error: response.ok ? null : `HTTP ${response.status}`,
          response_headers: responseHeaders,
          response_body: responseText,
          response_size: responseText.length,
          player: player_id
        })
      })
      .catch(error => {
        console.error(`Request failed: ${method} ${finalUrl} - Error:`, error)
        this.pushEvent("request_result", {
          success: false,
          method: method,
          url: finalUrl,
          status: 0,
          error: error.message,
          player: player_id
        })
      })
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
