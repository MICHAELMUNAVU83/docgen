defmodule DocgenWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DocgenWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the nav item to highlight, `:new` or `:history`"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-slate-200 bg-white px-4 sm:px-6">
      <div class="mx-auto flex h-16 max-w-6xl items-center justify-between">
        <.link navigate={~p"/"} id="brand" class="flex items-center gap-3">
          <img src={~p"/images/gs1_kenya.png"} alt="GS1 Kenya" class="h-10 w-auto" />
          <span class="border-l border-slate-200 pl-3 text-sm font-semibold tracking-tight text-gs1-navy">
            Docgen
          </span>
        </.link>
        <nav id="main-nav" class="flex h-full items-stretch gap-6 text-sm">
          <.link
            :for={{key, label, path} <- [{:new, "New", ~p"/"}, {:history, "History", ~p"/history"}]}
            navigate={path}
            id={"nav-#{key}"}
            aria-current={@active == key && "page"}
            class={[
              "-mb-px flex items-center border-b-2 font-medium transition-colors",
              if(@active == key,
                do: "border-gs1-orange text-gs1-navy",
                else: "border-transparent text-slate-600 hover:text-gs1-navy"
              )
            ]}
          >
            {label}
          </.link>
        </nav>
      </div>
    </header>

    <main class="min-h-[calc(100vh-4rem)] bg-white px-4 py-8 sm:px-6 sm:py-10">
      <div class="mx-auto max-w-6xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
