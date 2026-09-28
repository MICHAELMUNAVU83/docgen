defmodule Docgen.AI.RefinerTest do
  use ExUnit.Case, async: true

  alias Docgen.AI.Refiner

  test "reconstructs a flattened performance table without changing its values" do
    markdown = """
    ## Performance assessment

    Ratings reflect the supervisor's assessment.

    # Area Rating Comment

    Technical Skills **85%** Solid across backend, frontend and IoT

    Quality of Work **90%** Careful, thorough work with low rework

    **Overall** **85%** Average of the areas above

    Lucy has performed very well.
    """

    refined = Refiner.refine_markdown(markdown)

    assert refined =~ "| Area | Rating | Comment |"
    assert refined =~ "| Technical Skills | 85% | Solid across backend, frontend and IoT |"
    assert refined =~ "| Overall | 85% | Average of the areas above |"
    refute refined =~ "# Area Rating Comment"
    assert refined =~ "Lucy has performed very well."
  end

  test "leaves ordinary percentage prose unchanged" do
    source = "Uptake reached **85%** this year.\n"
    assert Refiner.refine_markdown(source) == source
  end
end
