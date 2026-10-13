defmodule Docgen.AI.Visuals do
  @moduledoc """
  Makes a presentation visual: for the slides that can take one
  (`Docgen.Render.Pptx.Deck.visual_candidates/1`) the model picks

    * a **chart**, when the slide or table states figures worth comparing —
      only figures that are in the text;
    * a **GS1 icon**, when the slide is about one of the sectors in the GS1
      icon set (`Docgen.Template.cover_icons/0`);
    * a **photo** from Unsplash, when a real-world scene would help. It
      writes the search, `Docgen.Unsplash` returns a few candidates, and
      the model then looks at them and keeps the one that fits, or none.

  The result maps `visual_candidates/1` keys to
  `t:Docgen.Render.Pptx.Deck.visual/0` and goes in the document's
  `meta.visuals`. Visuals are a nicety: any failure just means fewer of
  them.

  Charts and icons need an OpenAI key, photos an Unsplash key. With only
  an Unsplash key, slide titles are searched as they are and the top match
  is used unchecked.
  """

  alias Docgen.Render.Pptx.Deck
  alias Docgen.Unsplash

  @endpoint "https://api.openai.com/v1/responses"
  @max_photos 5
  @max_visuals 8
  @max_points 8
  @candidates 3

  @typedoc "Reported to `:progress` as the work moves on."
  @type stage :: :planning | :searching | :checking | :downloading

  @doc "True when at least one kind of visual can be made."
  @spec available?() :: boolean()
  def available? do
    Unsplash.configured?() or
      Application.get_env(:docgen, Docgen.AI.Planner, [])[:api_key] not in [nil, ""]
  end

  @doc """
  Visuals for `doc`'s slides, by candidate key.

  ## Options

    * `:max` — the most photos to add (default #{@max_photos})
    * `:progress` — called with each `t:stage/0` as it starts
    * `:api_key`, `:model`, `:client` — override the `Docgen.AI.Planner` configuration
    * `:unsplash` — options for `Docgen.Unsplash`
  """
  @spec find(Docgen.Document.t(), keyword()) :: %{term() => Deck.visual()}
  def find(%Docgen.Document{} = doc, opts \\ []) do
    opts = Keyword.merge(Application.get_env(:docgen, Docgen.AI.Planner, []), opts)
    unsplash = Keyword.get(opts, :unsplash, [])
    photos? = Unsplash.configured?(unsplash)
    progress = Keyword.get(opts, :progress, fn _stage -> :ok end)

    progress.(:planning)
    plans = doc |> Deck.visual_candidates() |> plan(doc, photos?, opts)

    drawn = for {slide, %{kind: kind} = visual} <- plans, kind != :search, do: {slide.key, visual}

    searches =
      for({slide, %{kind: :search, query: query}} <- plans, do: {slide, query})
      |> Enum.take(Keyword.get(opts, :max, @max_photos))

    Map.new(drawn ++ photos(searches, unsplash, progress, opts))
  end

  defp photos([], _unsplash, _progress, _opts), do: []

  defp photos(searches, unsplash, progress, opts) do
    progress.(:searching)

    found =
      concurrently(searches, fn {slide, query} ->
        case Unsplash.search(query, Keyword.put(unsplash, :per_page, @candidates)) do
          {:ok, [_ | _] = photos} -> {slide, query, photos}
          _ -> nil
        end
      end)

    if found != [], do: progress.(:checking)
    chosen = choose(found, opts)
    if chosen != [], do: progress.(:downloading)

    concurrently(chosen, fn {slide, photo} ->
      case Unsplash.download(photo, unsplash) do
        {:ok, image} -> {slide.key, %{kind: :photo, image: image, credit: photo.credit}}
        _ -> nil
      end
    end)
  end

  defp concurrently(items, fun) do
    items
    |> Task.async_stream(fun, timeout: :infinity, max_concurrency: 4)
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, result} -> [result]
    end)
  end

  ## Step 1: a visual for each slide that deserves one

  defp plan([], _doc, _photos?, _opts), do: []

  defp plan(slides, doc, photos?, opts) do
    listing =
      slides
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {slide, index} ->
        "[#{index}] (#{slide.kind}) #{slide.title}\n#{String.slice(slide.text, 0, 600)}"
      end)

    input = "Presentation: #{doc.meta[:title] || "untitled"}\n\nSlides:\n#{listing}"

    case ask(input, plan_instructions(photos?), plan_schema(photos?), opts) do
      {:ok, %{"visuals" => visuals}} when is_list(visuals) ->
        visuals
        |> Enum.flat_map(fn visual ->
          with index when is_integer(index) and index >= 0 <- visual["slide"],
               %{} = slide <- Enum.at(slides, index),
               %{} = planned <- planned(visual, slide, photos?) do
            [{slide, planned}]
          else
            _ -> []
          end
        end)
        |> Enum.uniq_by(fn {slide, _visual} -> slide.key end)
        |> Enum.take(@max_visuals)

      # Without the model, photos are searched by slide title.
      _ when photos? ->
        for %{kind: :content} = slide <- slides, do: {slide, %{kind: :search, query: slide.title}}

      _ ->
        []
    end
  end

  # Whatever the model returns, a chart has real points, an icon exists and
  # a table only ever gets a chart.
  defp planned(%{"kind" => "chart", "points" => points} = visual, _slide, _photos?)
       when is_list(points) do
    points =
      for %{"label" => label, "value" => value} <- points,
          is_binary(label) and String.trim(label) != "" and is_number(value),
          do: {String.trim(label), value}

    case Enum.take(points, @max_points) do
      [] ->
        nil

      points ->
        %{
          kind: :chart,
          chart: %{
            type: if(length(points) == 1, do: :number, else: :bar),
            title: text(visual["title"]),
            unit: text(visual["unit"]),
            points: points
          }
        }
    end
  end

  defp planned(%{"kind" => "icon", "icon" => slug}, %{kind: :content}, _photos?) do
    with {:ok, png} <- Docgen.Template.cover_icon(slug),
         %{} = image <- Docgen.Image.new("icon.png", png) do
      %{kind: :icon, image: image}
    else
      _ -> nil
    end
  end

  defp planned(%{"kind" => "photo", "query" => query}, %{kind: :content}, true)
       when is_binary(query) do
    if String.trim(query) == "", do: nil, else: %{kind: :search, query: String.trim(query)}
  end

  defp planned(_visual, _slide, _photos?), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp plan_instructions(photos?) do
    """
    You make a GS1 business presentation visual. Go through the slides and give a visual to the ones it would help, at most #{@max_visuals}, spread across the deck. Use the first kind that applies:

    1. chart — the slide or table states two or more comparable figures (percentages, counts, amounts, a series over time), or one headline figure. Copy the labels and values exactly as written; never invent, estimate or round them. Give the points in the order they appear, at most #{@max_points}, a short title, and the unit ("%", "KES", "stores", or "" when there is none). A "(table)" slide can only take a chart.
    2. icon — the slide is clearly about one sector in this GS1 icon set, and an icon says so at a glance: #{icon_catalogue()}.
    #{if photos?, do: photo_instruction(), else: ""}
    Skip agendas, references, contact details, thank-yous and slides where no visual adds anything. Return fewer visuals, or none, rather than forcing a weak one.

    Every item needs every field: use "" for a text field and [] for points that don't apply to its kind.
    """
  end

  defp photo_instruction do
    """
    3. photo — a real-world scene would make the point more vivid. Write an Unsplash search of 2 to 4 plain English words naming something a camera can capture: people at work, a place, an object. Match the deck's industry and region when it has one. Never use brand or product names, logos, charts, screenshots, text or abstract ideas. Use at most #{@max_photos} photos.
    """
  end

  defp icon_catalogue do
    Enum.map_join(Docgen.Template.cover_icons(), ", ", fn {slug, label} ->
      "#{slug} (#{label})"
    end)
  end

  defp plan_schema(photos?) do
    schema("slide_visuals", "visuals", %{
      "slide" => %{"type" => "integer"},
      "kind" => %{
        "type" => "string",
        "enum" => if(photos?, do: ~w(chart icon photo), else: ~w(chart icon))
      },
      "query" => %{"type" => "string"},
      "icon" => %{
        "type" => "string",
        "enum" => ["" | Enum.map(Docgen.Template.cover_icons(), &elem(&1, 0))]
      },
      "title" => %{"type" => "string"},
      "unit" => %{"type" => "string"},
      "points" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["label", "value"],
          "properties" => %{"label" => %{"type" => "string"}, "value" => %{"type" => "number"}}
        }
      }
    })
  end

  ## Step 3: which photo candidate, if any

  defp choose([], _opts), do: []

  defp choose(found, opts) do
    content =
      found
      |> Enum.with_index()
      |> Enum.flat_map(fn {{slide, query, photos}, index} ->
        [
          %{
            "type" => "input_text",
            "text" =>
              "Slide #{index}: #{slide.title} — #{String.slice(slide.text, 0, 240)}\nSearched for: #{query}"
          }
          | photos
            |> Enum.with_index()
            |> Enum.flat_map(fn {photo, candidate} ->
              [
                %{"type" => "input_text", "text" => "Slide #{index}, candidate #{candidate}:"},
                %{"type" => "input_image", "image_url" => photo.thumb, "detail" => "low"}
              ]
            end)
        ]
      end)

    chosen =
      case ask(
             [%{"role" => "user", "content" => content}],
             choice_instructions(),
             choice_schema(),
             opts
           ) do
        {:ok, %{"picks" => picks}} when is_list(picks) ->
          for %{"slide" => index, "candidate" => candidate} <- picks,
              is_integer(index) and index >= 0 and is_integer(candidate) and candidate >= 0,
              {slide, _query, photos} <- [Enum.at(found, index)],
              photo = Enum.at(photos, candidate),
              do: {slide, photo}

        _ ->
          Enum.map(found, fn {slide, _query, [photo | _]} -> {slide, photo} end)
      end

    Enum.uniq_by(chosen, fn {slide, _photo} -> slide.key end)
  end

  defp choice_instructions do
    """
    You are checking stock photos for a business presentation. For every slide, look at its candidates and pick the one that clearly illustrates what the slide says and looks professional.

    Reject a candidate that shows readable text, logos, brand names or watermarks, that is off-topic, misleading, or unsuitable for a workplace audience. Return candidate -1 for a slide when none fits: a slide without a photo is better than one with the wrong photo.
    """
  end

  defp choice_schema do
    schema("slide_photo_picks", "picks", %{
      "slide" => %{"type" => "integer"},
      "candidate" => %{"type" => "integer"}
    })
  end

  ## OpenAI

  defp schema(name, list, properties) do
    %{
      "type" => "json_schema",
      "name" => name,
      "strict" => true,
      "schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => [list],
        "properties" => %{
          list => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => Map.keys(properties),
              "properties" => properties
            }
          }
        }
      }
    }
  end

  defp ask(input, instructions, schema, opts) do
    with key when key not in [nil, ""] <- opts[:api_key],
         client = Keyword.get(opts, :client, &Req.post/2),
         {:ok, %{status: status, body: %{"output" => output}}} when status in 200..299 <-
           client.(@endpoint,
             json: %{
               "model" => Keyword.get(opts, :model, "gpt-4o-mini"),
               "store" => false,
               "instructions" => instructions,
               "input" => input,
               "text" => %{"format" => schema}
             },
             auth: {:bearer, key},
             receive_timeout: Keyword.get(opts, :timeout, 45_000)
           ),
         text when is_binary(text) <- output_text(output) do
      Jason.decode(text)
    else
      _ -> :error
    end
  end

  defp output_text(output) when is_list(output) do
    Enum.find_value(output, fn
      %{"content" => content} when is_list(content) ->
        Enum.find_value(content, fn
          %{"type" => "output_text", "text" => text} -> text
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp output_text(_output), do: nil
end
