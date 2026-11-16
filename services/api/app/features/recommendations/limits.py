"""Limits shared by the recommendation ranking and the AI chat."""

# The most place cards ever shown for one request: the traveler picks from
# these, so a short list stays readable. Used by the ranking, the AI place
# query and the prompts.
MAX_SUGGESTIONS = 5

# Weather is scored only inside the forecast window of the weather service
# (its route allows 1-5 days). Beyond it the criterion is neutral and says so.
WEATHER_FORECAST_DAYS = 5
# Places are grouped into cells this many degrees wide (about 28 km) so one
# forecast serves nearby places, which keeps provider calls low.
FORECAST_CELL_DEGREES = 0.25
MAX_FORECAST_CELLS = 10
