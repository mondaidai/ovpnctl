
---

## `ovpnctl` - RutOS OpenVPN Control Package

This package provides a bridge between **OpenVPN** management interfaces, **RutOS's ubus** (OpenWrt/RutOS micro bus architecture), and the built-in **HTTP API (`FunctionService`)**, allowing you to monitor and manage active OpenVPN server instances directly on Teltonika routers.

---

### Key Features

* **Server discovery:** Detects active OpenVPN servers from UCI configuration and exposes them over the API and ubus.
* **Client monitoring:** Lists connected clients with session and traffic details from the OpenVPN management interface.
* **Client kick:** Disconnects selected clients from a target OpenVPN server.
* **ubus integration:** Registers per-server objects under `openvpn.`.
* **HTTP API:** Provides endpoints for listing servers, listing clients, and kicking clients via RutOS's service framework.

---

### Available API Endpoints

| Method | Endpoint | Description |
| --- | --- | --- |
| **GET** | `/api/ovpnctl/servers` | Returns a list of all active OpenVPN servers with management interfaces. |
| **GET** | `/api/ovpnctl/list/{server_name}` | Fetches active connected clients for a specific OpenVPN server via ubus. |
| **POST** | `/api/ovpnctl/actions/kick` | Kicks one or more specified clients from the target OpenVPN server. |

---

### Available ubus Calls

Each discovered OpenVPN server is registered dynamically as a ubus object under the `openvpn.` namespace.

| Action / Method | ubus Object & Path | Description |
| --- | --- | --- |
| **CALL** | `openvpn. list` | Returns the currently connected clients for that specific OpenVPN server. |
| **CALL** | `openvpn. kick` | Disconnects one or more specified clients. Accepts a `clients` array argument (e.g., `{"clients": ["client1"]}`). |

---

### How it Works

1. **Background Daemon (`--ubus`):** When run with the `--ubus` flag, it registers objects into the system ubus broker and periodically refreshes server configurations using `uloop`.
2. **API Service:** The module uses RutOS's `FunctionService` framework to seamlessly register the routing mapping (`/ovpnctl/{service_group}/{sid}`) and process web/API requests.

---
