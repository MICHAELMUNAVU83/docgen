defmodule Docgen.Render.Pptx.Chart do
  @moduledoc """
  Draws a slide's chart from plain shapes, in the GS1 colours, so it stays
  editable in PowerPoint without an embedded workbook.

  A chart is `%{type: :bar | :number, title: text, unit: text, points:
  [{label, number}]}`: `:bar` compares its points as horizontal bars,
  `:number` shows a single figure large.
  """

  alias Docgen.Render.Pptx.Xml

  @navy "002C6C"
  @orange "F26334"
  @grey "454545"

  @type t :: %{
          type: :bar | :number,
          title: String.t(),
          unit: String.t(),
          points: [{String.t(), number()}]
        }

  @doc """
  The shapes of `chart` inside `{x, y, cx, cy}` (EMU), with shape ids from
  `first_id`. `size` is the label text size in hundredths of a point.
  """
  @spec shapes(t(), {integer(), integer(), integer(), integer()}, pos_integer(), pos_integer()) ::
          iodata()
  def shapes(chart, frame, first_id, size \\ 900)

  def shapes(%{type: :number, points: [{label, value} | _]} = chart, {x, y, cx, cy}, id, size) do
    figure = div(cy, 3)

    [
      Xml.text_box(id, "Figure", {x, y + div(cy, 6), cx, figure}, [
        paragraph(format(value, chart.unit), size * 5, "ctr", @orange, true)
      ]),
      Xml.text_box(id + 1, "Figure label", {x, y + div(cy, 6) + figure, cx, div(cy, 4)}, [
        paragraph(label, round(size * 1.4), "ctr", @navy, false)
      ])
    ]
  end

  def shapes(%{type: :bar, points: points} = chart, {x, y, cx, cy}, id, size) do
    title_height = size * 127 * 2
    row = min(div(cy - title_height, max(length(points), 1)), size * 127 * 4)
    bar = div(row * 55, 100)
    text = div(size * 127 * 13, 10)
    label_width = div(cx * 38, 100)
    bar_x = x + label_width + div(cx * 3, 100)
    bar_width = div(cx * 41, 100)
    largest = points |> Enum.map(fn {_label, value} -> abs(value) end) |> Enum.max(fn -> 0 end)
    largest = if largest == 0, do: 1, else: largest

    rows =
      points
      |> Enum.with_index()
      |> Enum.map(fn {{label, value}, index} ->
        top = y + title_height + index * row
        width = max(round(bar_width * abs(value) / largest), 12_700)
        shape = id + 1 + index * 3

        [
          Xml.text_box(shape, "Label", {x, top + div(row - text, 2), label_width, text}, [
            paragraph(label, size, "r", @grey, false)
          ]),
          Xml.rect(shape + 1, {bar_x, top + div(row - bar, 2), width, bar}, @navy),
          Xml.text_box(
            shape + 2,
            "Value",
            {bar_x + width + div(cx * 2, 100), top + div(row - text, 2), div(cx * 16, 100), text},
            [paragraph(format(value, chart.unit), size, "l", @navy, true)]
          )
        ]
      end)

    [
      Xml.text_box(id, "Chart title", {x, y, cx, title_height}, [
        paragraph(chart.title, round(size * 1.1), "l", @navy, true)
      ]),
      rows
    ]
  end

  @doc "A value as it is labelled: whole numbers without decimals, then the unit."
  @spec format(number(), String.t()) :: String.t()
  def format(value, unit) do
    number =
      if value == trunc(value),
        do: Integer.to_string(trunc(value)),
        else: :erlang.float_to_binary(value * 1.0, decimals: 1)

    case String.trim(unit || "") do
      "" -> number
      "%" -> number <> "%"
      unit -> number <> " " <> unit
    end
  end

  defp paragraph(text, size, align, colour, bold?) do
    [
      ~s(<a:p><a:pPr algn="#{align}" marL="0" indent="0"><a:buNone/></a:pPr>),
      ~s(<a:r><a:rPr lang="en-GB" sz="#{size}" b="#{if bold?, do: 1, else: 0}" dirty="0">),
      ~s(<a:solidFill><a:srgbClr val="#{colour}"/></a:solidFill></a:rPr><a:t>),
      Xml.escape(text),
      "</a:t></a:r></a:p>"
    ]
  end
end
