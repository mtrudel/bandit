defmodule DateHelpers do
  @moduledoc false

  @regex ~r/(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (?:[0-2][0-9]|3[0-1]) (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} (?:[0-1][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] GMT/

  def valid_date_header?(date_header) do
    Regex.match?(@regex, date_header)
  end
end
