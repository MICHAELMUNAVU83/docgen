defmodule Docgen.AI.VisualsTest do
  use ExUnit.Case, async: true

  alias Docgen.AI.Visuals
  alias Docgen.UnsplashStub

  @markdown """
  # Warehouse scanning

  - Scan every pallet
  - Fewer errors

  # Store shelves

  - Always in stock
  """

  defp doc,
    do: Docgen.parse(@markdown, :markdown, template: :presentation, meta: %{title: "Rollout"})

  defp unsplash(photos \\ 3), do: [access_key: "key", client: UnsplashStub.client(self(), photos)]

  # Answers the two model calls: a visual per slide, then which photo.
  defp model(visuals, picks \\ []) do
    test = self()
    blank = %{"query" => "", "icon" => "", "title" => "", "unit" => "", "points" => []}

    fn _url, request ->
      send(test, {:model, request[:json]})

      answer =
        case request[:json]["text"]["format"]["name"] do
          "slide_visuals" -> %{"visuals" => Enum.map(visuals, &Map.merge(blank, &1))}
          "slide_photo_picks" -> %{"picks" => picks}
        end

      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(answer)}]}
           ]
         }
       }}
    end
  end

  test "the model writes the searches and picks among the candidates it is shown" do
    client =
      model(
        [
          %{"slide" => 0, "kind" => "photo", "query" => "forklift pallets"},
          %{"slide" => 1, "kind" => "photo", "query" => "supermarket"}
        ],
        [%{"slide" => 0, "candidate" => 1}, %{"slide" => 1, "candidate" => -1}]
      )

    visuals = Visuals.find(doc(), api_key: "sk", client: client, unsplash: unsplash())

    # The second slide's candidates were all rejected.
    assert Map.keys(visuals) == ["Warehouse scanning"]

    assert %{kind: :photo, credit: "Photo: Photographer 2 / Unsplash", image: image} =
             visuals["Warehouse scanning"]

    assert image.content_type == "image/jpeg"
  end

  test "the model is shown each candidate's thumbnail" do
    client =
      model([%{"slide" => 0, "kind" => "photo", "query" => "forklift"}], [
        %{"slide" => 0, "candidate" => 0}
      ])

    Visuals.find(doc(), api_key: "sk", client: client, unsplash: unsplash())

    assert_received {:model, %{"input" => "Presentation: Rollout" <> _}}
    assert_received {:model, %{"input" => [%{"content" => content}]}}

    assert for(%{"type" => "input_image", "image_url" => url} <- content, do: url) ==
             ~w(https://images.example/thumb-1 https://images.example/thumb-2 https://images.example/thumb-3)
  end

  describe "charts and icons" do
    @figures """
    # Results

    Scanning errors fell sharply.

    | Region | Stores |
    | --- | --- |
    | East | 72 |
    | West | 48 |

    # Retail

    - In every store
    """

    defp figures, do: Docgen.parse(@figures, :markdown, template: :presentation)

    test "a table's figures become a chart and a sector slide gets its GS1 icon" do
      candidates = Docgen.Render.Pptx.Deck.visual_candidates(figures())

      assert [%{key: "Results"}, %{key: {:table, "Results"}, text: table}, %{key: "Retail"}] =
               candidates

      assert table =~ "East | 72"

      client =
        model([
          %{
            "slide" => 1,
            "kind" => "chart",
            "title" => "Stores by region",
            "unit" => "stores",
            "points" => [%{"label" => "East", "value" => 72}, %{"label" => "West", "value" => 48}]
          },
          %{"slide" => 2, "kind" => "icon", "icon" => "retail"},
          %{
            "slide" => 0,
            "kind" => "chart",
            "title" => "Errors",
            "unit" => "%",
            "points" => [%{"label" => "Fewer errors", "value" => 40}]
          }
        ])

      visuals =
        Visuals.find(figures(), api_key: "sk", client: client, unsplash: [access_key: nil])

      assert visuals[{:table, "Results"}] == %{
               kind: :chart,
               chart: %{
                 type: :bar,
                 title: "Stores by region",
                 unit: "stores",
                 points: [{"East", 72}, {"West", 48}]
               }
             }

      assert %{kind: :icon, image: %{content_type: "image/png"}} = visuals["Retail"]

      assert %{kind: :chart, chart: %{type: :number, points: [{"Fewer errors", 40}]}} =
               visuals["Results"]

      # Nothing was searched, and no photo was offered to the model.
      refute_received {:unsplash, _, _}
      assert_received {:model, %{"text" => %{"format" => %{"schema" => schema}}}}
      assert get_in(schema, ~w(properties visuals items properties kind enum)) == ~w(chart icon)
    end

    test "made-up visuals are dropped" do
      client =
        model([
          %{"slide" => 0, "kind" => "chart", "title" => "Empty", "points" => []},
          %{"slide" => 1, "kind" => "icon", "icon" => "retail"},
          %{"slide" => 2, "kind" => "icon", "icon" => ""},
          %{"slide" => 9, "kind" => "icon", "icon" => "retail"},
          %{"slide" => 2, "kind" => "photo", "query" => "shop"}
        ])

      assert Visuals.find(figures(), api_key: "sk", client: client, unsplash: [access_key: nil]) ==
               %{}
    end

    test "progress is reported" do
      test = self()

      client =
        model([%{"slide" => 0, "kind" => "photo", "query" => "forklift"}], [
          %{"slide" => 0, "candidate" => 0}
        ])

      Visuals.find(doc(),
        api_key: "sk",
        client: client,
        unsplash: unsplash(),
        progress: &send(test, {:stage, &1})
      )

      for stage <- [:planning, :searching, :checking, :downloading],
          do: assert_received({:stage, ^stage})
    end
  end

  test "without a model the slide titles are searched and the top match used" do
    visuals = Visuals.find(doc(), api_key: nil, unsplash: unsplash())

    assert Map.keys(visuals) == ["Store shelves", "Warehouse scanning"]
    assert visuals["Store shelves"].credit == "Photo: Photographer 1 / Unsplash"
    assert_received {:unsplash, _, [{:params, [{:query, "Warehouse scanning"} | _]} | _]}
  end

  test "slides whose search finds nothing get no photo" do
    assert Visuals.find(doc(), api_key: nil, unsplash: unsplash(0)) == %{}
  end

  test "`:max` caps the number of photos" do
    assert map_size(Visuals.find(doc(), api_key: nil, max: 1, unsplash: unsplash())) == 1
  end

  test "without any key nothing is added" do
    assert Visuals.find(doc(), api_key: nil, unsplash: [access_key: nil]) == %{}
  end
end
