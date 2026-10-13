defmodule DocgenWeb.HistoryLive.Index do
  use DocgenWeb, :live_view

  require Logger

  alias Docgen.History

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "History")
     |> load_entries("")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:history}>
      <div class="space-y-6">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight text-gs1-navy">History</h1>
            <p class="mt-1 text-sm text-slate-600">
              Everything you've downloaded, newest first.
            </p>
          </div>
          <.form
            for={@search}
            id="history-search"
            phx-change="search"
            phx-submit="search"
            class="-mb-4 w-full sm:w-64"
          >
            <.input
              field={@search[:q]}
              type="search"
              placeholder="Search by title"
              aria-label="Search by title"
              phx-debounce="250"
              class="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 transition focus:border-gs1-navy focus:outline-none focus:ring-2 focus:ring-gs1-navy/20"
            />
          </.form>
        </div>

        <div
          :if={@error?}
          id="history-error"
          class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
        >
          History is unavailable right now — the database can't be reached.
        </div>

        <div
          :if={@empty? and not @error?}
          id="history-empty"
          class="rounded-lg border border-dashed border-slate-300 px-6 py-14 text-center"
        >
          <%= if @search[:q].value == "" do %>
            <p class="text-sm text-slate-600">
              Nothing yet — documents appear here after you download them.
            </p>
            <.link
              navigate={~p"/"}
              class="mt-4 inline-flex items-center gap-2 rounded-md bg-gs1-navy px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-gs1-navy-hover"
            >
              Create a document
            </.link>
          <% else %>
            <p class="text-sm text-slate-600">No documents match that search.</p>
          <% end %>
        </div>

        <ul
          id="history"
          phx-update="stream"
          class="divide-y divide-slate-200 border-y border-slate-200 empty:hidden"
        >
          <li
            :for={{dom_id, entry} <- @streams.entries}
            id={dom_id}
            class="flex flex-wrap items-center gap-x-4 gap-y-2 py-4"
          >
            <.icon
              name={
                if(entry.template == "presentation",
                  do: "hero-presentation-chart-bar",
                  else: "hero-document-text"
                )
              }
              class="size-5 shrink-0 text-slate-400"
            />
            <div class="min-w-0 flex-1 basis-48">
              <p class="truncate text-sm font-medium text-slate-900">{entry.title}</p>
              <p class="text-xs text-slate-500">
                GS1 {String.capitalize(entry.template)} ·
                <time
                  id={"time-#{entry.id}"}
                  phx-hook=".LocalTime"
                  datetime={DateTime.to_iso8601(entry.inserted_at)}
                >
                  {Calendar.strftime(entry.inserted_at, "%d %b %Y, %H:%M")} UTC
                </time>
              </p>
            </div>
            <div class="flex items-center gap-1 text-sm font-medium">
              <.link
                navigate={~p"/?from=#{entry.id}"}
                id={"open-#{entry.id}"}
                class="rounded-md px-2.5 py-1.5 text-gs1-navy transition hover:bg-gs1-navy/5"
              >
                Open
              </.link>
              <a
                href={~p"/history/#{entry.id}/download?format=#{native_ext(entry)}"}
                id={"download-native-#{entry.id}"}
                class="rounded-md px-2.5 py-1.5 text-gs1-navy transition hover:bg-gs1-navy/5"
              >
                .{native_ext(entry)}
              </a>
              <a
                href={~p"/history/#{entry.id}/download?format=pdf"}
                id={"download-pdf-#{entry.id}"}
                class="rounded-md px-2.5 py-1.5 text-gs1-navy transition hover:bg-gs1-navy/5"
              >
                PDF
              </a>
              <button
                id={"delete-#{entry.id}"}
                phx-click="delete"
                phx-value-id={entry.id}
                data-confirm="Delete this document from the history?"
                aria-label="Delete"
                class="rounded-md p-1.5 text-slate-400 transition hover:bg-red-50 hover:text-red-600"
              >
                <.icon name="hero-trash" class="size-5" />
              </button>
            </div>
          </li>
        </ul>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
        export default {
          mounted() { this.show() },
          updated() { this.show() },
          show() {
            const date = new Date(this.el.dateTime)
            if (isNaN(date)) return
            this.el.textContent = date.toLocaleString(undefined, {dateStyle: "medium", timeStyle: "short"})
          }
        }
      </script>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, load_entries(socket, String.trim(query))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> History.get!() |> History.delete()

    {:noreply, load_entries(socket, socket.assigns.search[:q].value)}
  end

  # Streams can't be counted, so the list is refetched to keep the empty
  # state right after a search or a delete.
  defp load_entries(socket, query) do
    {entries, error?} =
      try do
        {History.list(search: query), false}
      rescue
        error ->
          Logger.warning("Could not load document history: #{Exception.message(error)}")
          {[], true}
      catch
        # A pool that isn't running exits rather than raises.
        :exit, reason ->
          Logger.warning("Could not load document history: #{inspect(reason)}")
          {[], true}
      end

    socket
    |> assign(search: to_form(%{"q" => query}), empty?: entries == [], error?: error?)
    |> stream(:entries, entries, reset: true)
  end

  defp native_ext(entry), do: if(entry.template == "presentation", do: "pptx", else: "docx")
end
