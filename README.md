# Book Manager — Web Edition (Common Lisp)

A self-hosted book library manager built with **Hunchentoot**, **SQLite**, and a single-page HTML frontend. Register books by ISBN, auto-fetch titles from external APIs, and manage your reading list through a browser.

## File Structure

```
book-manager-web.lisp   ← Server & REST API (Hunchentoot + SQLite)
index.html              ← Frontend (single-file HTML + Tailwind CSS)
start.lisp              ← Startup script (load deps → launch server)
library.db              ← SQLite database (auto-created on first run)
```

## Setup

### 1. Prerequisites

- [SBCL](http://www.sbcl.org/) (or another ANSI Common Lisp with threads)
- [Quicklisp](https://www.quicklisp.org/)

### 2. Install Dependencies

```lisp
(ql:quickload '(:hunchentoot :cl-json :dexador :cl-ppcre
                :cl-dbi :dbd-sqlite3 :bordeaux-threads))
```

### 3. Start the Server

**Option A — From the REPL:**

```lisp
(load "book-manager-web.lisp")
(in-package :book-manager-web)
(start-server)          ; → http://localhost:8080
```

**Option B — Headless via `start.lisp`:**

```bash
sbcl --load start.lisp
```

The server runs until you press `Ctrl+C` or use the **Shutdown** button in the UI.

### 4. Stop the Server

From the REPL:

```lisp
(book-manager-web:stop-server)
```

Or click the **Shutdown** button in the web UI header (a confirmation dialog will appear).

---

## Usage

Open `http://localhost:8080` in your browser. The UI provides:

| Feature | Description |
|---|---|
| **+ Add** | Register a book by ISBN. Title is auto-fetched if left blank. |
| **Import ISBNs** | Paste multiple ISBNs (one per line) for bulk import. |
| **Search** | Filter by title or ISBN substring. |
| **Category / Status filters** | Narrow the list by category or read/unread status. |
| **Edit** | Change title, status, category, or priority. |
| **Delete** | Remove a book (with confirmation). |
| **Shutdown** | Gracefully stop the server from the browser. |

---

## REST API

All endpoints return JSON. The frontend uses these, but they can also be called directly.

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/books?q=&genre=&status=` | List books (with optional filters) |
| `POST` | `/api/books` | Add a book |
| `GET` | `/api/books/:isbn` | Retrieve a single book |
| `PUT` | `/api/books/:isbn` | Update a book |
| `DELETE` | `/api/books/:isbn` | Delete a book |
| `GET` | `/api/genres` | List all distinct categories |
| `POST` | `/api/import` | Bulk import by ISBN list |
| `POST` | `/api/shutdown` | Shut down the server |

### Examples

**Add a book:**

```bash
curl -X POST http://localhost:8080/api/books \
  -H "Content-Type: application/json" \
  -d '{"isbn":"9784873119038","genre":"Programming","priority":1}'
```

**List all unread books:**

```bash
curl "http://localhost:8080/api/books?status=unread"
```

**Mark a book as read:**

```bash
curl -X PUT http://localhost:8080/api/books/9784873119038 \
  -H "Content-Type: application/json" \
  -d '{"read_status":"read"}'
```

**Bulk import:**

```bash
curl -X POST http://localhost:8080/api/import \
  -H "Content-Type: application/json" \
  -d '{"isbns":["9784873119038","9784873118963","9784621300527"]}'
```

---

## Data Schema

Each book is stored as a row in the `books` table:

| Column | Type | Description |
|---|---|---|
| `isbn` | `TEXT` (PK) | ISBN-13 (digits only) |
| `title` | `TEXT` | Book title |
| `read_status` | `TEXT` | `read` or `unread` |
| `priority` | `INTEGER` | 1 (highest) – 5 (lowest) |
| `genre` | `TEXT` | Category (default: `Uncategorized`) |

---

## Title Auto-Fetch

When a book is added without a title, the server attempts to fetch it from three APIs in order:

1. **National Diet Library (NDL)** — best coverage for Japanese books
2. **Google Books API** — broad international coverage
3. **Open Library API** — good for English-language books

All API calls have configurable timeouts (`*api-connect-timeout*`, `*api-read-timeout*`) so a slow or unreachable service does not block the request. If none of the APIs return a title, the book is saved as `(Title not found)` and can be edited later.

---

## Architecture Notes

- **SQLite** via `cl-dbi` + `dbd-sqlite3` — no external database server required.
- **Thread safety** — all write operations are wrapped in `bt:with-lock-held`.
- **RESTful routing** — a custom Hunchentoot dispatcher extracts `:isbn` from the URI path since `define-easy-handler` does not support path parameters.
- **Frontend** — a single `index.html` served from disk; uses Tailwind CSS via CDN and vanilla JavaScript (no build step).

---

## License

This project is provided as-is for personal use.
