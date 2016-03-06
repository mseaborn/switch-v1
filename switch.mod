########################################
#    Copyright 2007-2012, Matthias Fripp
#
#    This file is part of Switch (a power system planning model).
#
#    Switch is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License version 3 
#    as published by the Free Software Foundation. Modified versions
#    of Switch must include this notice and the AUTHOR ATTRIBUTION
#    / CITATION notice below.
#
#    Switch is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with Switch.  If not, see <http://www.gnu.org/licenses/>.
#
#    AUTHOR ATTRIBUTION / CITATION
#
#    In publications based on analysis conducted with Switch, please cite 
#    Matthias Fripp (2012), "Switch: A Planning Tool for Power Systems 
#    with Large Shares of Intermittent Renewable Energy", Environmental Science
#    & Technology 46 (11), pp 6371Ð6378, http://dx.doi.org/10.1021/es204645c
#
#    In presentations based on analysis conducted with Switch, please cite the
#    Switch project's website at http://www.switch-model.org
#
########################################



# TODO near term: 
# - incorporate the interruptible load and demand elasticity into the objective function on an hourly basis
# before using those for anything, and also copy them into calculate_results.run

# TODO longer term:
# - split study hours into reserve and non-reserve (maybe just by inspection of the weighting),
# and give no weight to the reserve hours during the main economic analysis, and no attention to the
# main hours in the reserve calculation constraint? (this would speed up calculation, but would be a
# bad idea if reserves are an important part of costs and reserve requirements are dominated by non-peak
# load conditions [e.g., moderate load and low wind]).
# - incorporate improved maximum capacity constraint from long-term study sensitivity case,
# to allow for rebuilding new plants after they are retired (in long studies)
# - try using the "mini" model to develop a basis, which is then applied to the full-scale model
# - change the load data to provide some days that are just used for reserve planning, 
# and others that are used for cost optimization (e.g., just do reserve optimization based on peak days, 
# then do the main optimization on other days)
# - Change the economic analysis to assume that plants are built linearly over the course of the investment
# period(s), and then to report the costs in the last year of each investment period 
# (rather than assuming they are the same in all years of the period). This would allow for running the
# model with a single investment period and getting meaningful results about the system at the end.


###############################################
#
# Time-tracking parameters
#

set YEARS ordered; # all possible years
set HOURS ordered;

# each hour is assigned to a study period exogenously,
# so that we don't have to do any arithmetic to figure out
# which hour is in each period. This allows for arbitrary
# numbering of the hours, so they need not be spaced integral
# number of hours apart through the whole year. This is important
# if we want to sample, e.g., 12*24 hours per year or per 3 years.
# Another way to do it would be to exogenously specify
# how many samples there are per study period, and then bundle
# them up within the model. That would allow us to change the length
# of the study period from inside the model.
# But it wouldn't gain us very much, since the sampling must be
# done carefully for each study period anyway.

# note: periods must be evenly spaced and count by years, 
# but they can have decimals (e.g., 2006.5 for July 1, 2006)
# and be any distance apart.
# VINTAGE_YEARS are a synonym for PERIODS, but refer more explicitly
# the date when a power plant starts running.
set PERIODS ordered;
set VINTAGE_YEARS ordered = PERIODS;

# chronological information on each study hour (sample)
# this is used to identify which hours fall in each study period
# and how many real hours are represented by each sample (which may be fractional).
# Hour_of_day and month_of_year are just used for reporting (if that)
param period {HOURS} in PERIODS; 
param date {HOURS};
param hours_in_sample {HOURS};
param hour_of_day {HOURS};
param month_of_year {HOURS};
param season_of_year {h in HOURS} = floor((month_of_year[h]-1)/3)+1;

# specific dates are used to collect hours that are part of the same
# day, for the purpose of hydro dispatch, etc.
set DATES ordered = setof {h in HOURS} (date[h]);

# it's sometimes useful to know which period each date falls into
param period_of_date {d in DATES} := period[min {h in HOURS: date[h]=d} h];
check {h in HOURS}: period_of_date[date[h]] = period[h];

set HOURS_OF_DAY ordered = setof {h in HOURS} (hour_of_day[h]);
set MONTHS_OF_YEAR ordered = setof {h in HOURS} (month_of_year[h]);
set SEASONS_OF_YEAR ordered = setof {h in HOURS} (season_of_year[h]);

# make sure every HOUR_OF_DAY is modeled on every date
# (this could be relaxed later, but is currently assumed true for the daily constraint on simple hydro dispatch)
check card(HOURS_OF_DAY) * card(DATES) = card(HOURS); 

# the date (year and fraction) when the optimization starts
param start_year = first(PERIODS);

# interval between study periods
# this is calculated from the study period intervals if possible,
# otherwise it's assumed to be just a one-year study
param years_per_period >= 0 
  default if last(PERIODS) = first(PERIODS) then 1 else (last(PERIODS)-first(PERIODS))/(card(PERIODS)-1);

# the first year that is beyond the simulation
# (i.e., this would be the first year of the next simulation, if there were one)
param end_year = last(PERIODS)+years_per_period;

# number of clock hours during each calendar year
# (these may not all be represented by available samples)
# this is used to convert annual costs into hourly costs
# (users can change this in switch.dat if they use a different weighting system)
param hours_per_year default 8766;

# Make sure the model either has exactly enough or a significant subsample of the hours 
# needed to cover the full study period. Anything else is probably an error.
check (sum {h in HOURS} hours_in_sample[h])/(end_year-start_year) = hours_per_year
  or ((sum {h in HOURS} hours_in_sample[h])/(end_year-start_year)) <= 0.7*hours_per_year;

###############################################
#
# System loads and zones
#

# list of all load zones in the state
# it is ordered, so they are listed from north to south
set LOAD_ZONES ordered;

# base-case system load (MWa):
# part is fixed to happen during a particular hour,
# part can be moved to any hour of the day
# NOTE: if an annual electricity demand curve is provided, 
# the fixed portion of load will be adjusted up or down from this level
param system_load_fixed {LOAD_ZONES, HOURS} >= 0;
param system_load_moveable {LOAD_ZONES, DATES} >= 0 default 0;

# peak system-wide load during each study period
param system_load_peak {p in PERIODS} 
  = max {h in HOURS: period[h]=p} sum {z in LOAD_ZONES} system_load_fixed[z, h];

# planning reserve margin - fractional extra load the system must be able able to serve
# when there are no forced outages
param planning_reserve_margin >= 0;

##############################################
#
# Piecewise supply curves for two types of demand response or efficiency:
# - "interruptible load" can be turned off during critical peak hours, in exchange for some payment.
# - "annual demand" scales the loads in each zone up or down depending on the price of power
# The cost of interruptible load would most likely be paid out as part of a capacity auction.
# The annual demand curve indicates the benefit of providing power to customers.
# It could also be interpreted as the cost of energy efficiency projects that save power and
# leave the customers just as well off as they were to begin with. Or it could be the amount that
# some customers would have to be paid to reduce their year-round consumption (maybe that would 
# have to be the difference between the cost of producing power and the benefit of using it.)
# Note that this formulation allows demand reduction to be included in one study period and 
# left unused in the next one; there is currently no treatment of sunk costs (e.g., for efficiency projects).

# interruptible load (IL) reduces the need for reserve margins, but has no effect on normal dispatch
#    (mostly because I can't think of a way to get the interruptible load to be dispatched after everything else,
#     without also changing how much of it gets built. i.e., if I use a high dispatch cost, we will be less inclined
#     to build it. the only other way is some sort of "if" constraint: if reserve margin can be met without interruptible
#     load, then do so; otherwise, dispatch enough interruptible load to keep reserves up [which may also reduce loads]) 

# TODO: change interrruptible load formulation to use an exogenously specified supply curve, 
# like annual demand, and eliminate the other parameters.

# elasticity of interruptible load
# this is the amount (in dollars per kw-year) by which the cost of 
# interruptible load increases for each percent of the system peak load
# that is satisfied with interruptible load
param interruptible_load_cost_per_kw_year_per_percent_peak_load >= 0 default 0;

# the maximum amount of interruptible load that can be used in any load zone
# (specified as a fraction of the peak load, e.g., 0.20)
param interruptible_load_max_share >= 0 default 0;

# the total cost of developing interruptible load is quadratic in the
# amount developed, but we approximate it using a piecewise-linear curve.
# this tells how many segments are in that curve
param interruptible_load_cost_segment_count >= 0 default 5;

# Points along a stepwise demand curve for electricity (on an annual time scale).
# The first and last breakpoints show the minimum and maximum possible
# annual demand (as a fraction of base-case year round power consumption in each zone).
# Between those is shown the power price that would induce each level of demand
# (or, equivalently, the benefit delivered [to customers] by generating additional power
# when the total supply is at each level).
# The power prices are expressed as fractions of a base-case price in each zone.
# The price levels are assumed to apply at or above each breakpoint.
# The last price level is never used, because it is above the highest allowed load.
# To use a fixed power demand instead of a supply curve, just use the default values
# (one breakpoint with a quantity and price of 1). 

set ANNUAL_DEMAND_BREAKPOINTS ordered default {1};
param annual_demand_quantity_vs_base {ANNUAL_DEMAND_BREAKPOINTS} >= 0 default 1;
param annual_demand_price_vs_base {ANNUAL_DEMAND_BREAKPOINTS} default 1;
# demand curve must be strictly non-increasing 
# (if it dropped and rose, that would create local maxima in the total benefit curve)
check {bp in ANNUAL_DEMAND_BREAKPOINTS: ord(bp) > 1}: 
  annual_demand_quantity_vs_base[bp] >= annual_demand_quantity_vs_base[prev(bp)];
check {bp in ANNUAL_DEMAND_BREAKPOINTS: ord(bp) > 1}: 
  annual_demand_price_vs_base[bp] <= annual_demand_price_vs_base[prev(bp)];

# base-case marginal cost or value of year-round power
# this could be specified differently for each period, but for now, 
# we use a single value for each zone, and just read it from the .dat file.
param annual_demand_price_base {LOAD_ZONES} >= 0 default 0;

# note: base-case electricity demand is specified by system_load_fixed
# TODO: rename system_load_fixed to fit better with the supply curve paradigm

# note: "base-case" and "base" in the power demand curves refer to the single known
# price/quantity point on the curve, i.e., the power consumption forecasted for some future
# period and the marginal benefit of supplying that power, or the marginal price used for that forecast. 
# The base-case consumption is usually provided by some state agency, and the base-case benefit 
# can be found by running this model in a way consistent with that forecast, with demand curve
# constrained to be vertical, and then reading out the dual values of the vertical constraint on the 
# demand curve (i.e., the marginal cost of providing that power). 
# e.g., if the forecaster says they assumed future costs would be the same as the past, you can
# get the historical marginal cost of power by running the model for an historical year. 
# (see load_historical_year.run, then you can use this command to get suitable costs to put in windsun.dat:
# display {z in LOAD_ZONES} Minimum_Maximum_Annual_Demand[z, first(PERIODS)] / annual_cost_weight[first(PERIODS)];
# These costs may not match the customer prices used by the forecaster,
# but they should have the same relationship to those prices as future marginal costs have to
# future prices faced by electricity customers (at least as a first guess).
# At any rate, "base-case" and "base" do not refer to a base-case future scenario or to 
# baseload power production; they only refer to the single, known price/quantity point
# on the demand curve.

###############################################
#
# Technology specifications
# (most of these come from generator_costs.dat or windsun.dat)

# list of all available technologies (from the generator cost table)
set TECHNOLOGIES;

# list of all possible fuels
set FUELS; 

# earliest time when each technology can be built
param min_vintage_year {TECHNOLOGIES} >= 0;

# overnight cost for the plant ($/kW), if built in a particular year
param capital_cost_by_vintage {TECHNOLOGIES, YEARS} >= 0 default Infinity;

# cost of grid upgrades to deliver power from the new plant to the "center" of the load zone
# (specified generically for all projects of a given technology, also specified per-project below.
# if specified in both places, the two will be summed; usually one of them will be zero.)
param connect_cost_per_kw_generic {TECHNOLOGIES} >= 0;

# fixed O&M ($/kW-year)
param fixed_o_m {TECHNOLOGIES} >= 0;

# variable O&M ($/MWh)
param variable_o_m {TECHNOLOGIES} >= 0;

# fuel used by this type of plant
param fuel {TECHNOLOGIES} symbolic in FUELS;

# heat rate (in Btu/kWh)
param heat_rate {TECHNOLOGIES} >= 0;

# life of the plant (age when it must be retired)
param max_age_years {TECHNOLOGIES} >= 0;

# fraction of the time when a plant will be unexpectedly unavailable
param forced_outage_rate {TECHNOLOGIES} >= 0, <= 1;

# fraction of the time when a plant must be taken off-line for maintenance
param scheduled_outage_rate {TECHNOLOGIES} >= 0, <= 1;

# does the generator have a fixed hourly capacity factor?
param intermittent {TECHNOLOGIES} binary;

# can this type of project only be installed in limited amounts?
param resource_limited {TECHNOLOGIES} binary;

###############################################
# Project data

# default values for projects that don't have sites or orientations
param site_unspecified symbolic;
param orient_unspecified symbolic;

# Names of technologies that have capacity factors or maximum capacities 
# tied to specific locations. 
param tech_pv symbolic in TECHNOLOGIES;
param tech_trough symbolic in TECHNOLOGIES;
param tech_wind symbolic in TECHNOLOGIES;

# names of other technologies, just to have them around 
# (but this is getting silly)
param tech_ccgt symbolic in TECHNOLOGIES;
param tech_ct symbolic in TECHNOLOGIES;

# maximum capacity factors (%) for each project, each hour. 
# generally based on renewable resources available
set PROJ_INTERMITTENT_HOURS dimen 5;  # LOAD_ZONES, TECHNOLOGIES, SITES, ORIENTATIONS, HOURS
param cap_factor {PROJ_INTERMITTENT_HOURS} >= 0, <= 1;
set PROJ_INTERMITTENT = setof {(z, t, s, o, h) in PROJ_INTERMITTENT_HOURS} (z, t, s, o);
# make sure all hours are represented
check {(z, t, s, o) in PROJ_INTERMITTENT, h in HOURS}: cap_factor[z, t, s, o, h] >= 0;
check {(z, t, s, o) in PROJ_INTERMITTENT}: intermittent[t];

# maximum capacity (MW) that can be installed in each project
set PROJ_RESOURCE_LIMITED dimen 4;  # LOAD_ZONES, TECHNOLOGIES, SITES, ORIENTATIONS
param max_capacity {PROJ_RESOURCE_LIMITED} >= 0;
check {(z, t, s, o) in PROJ_RESOURCE_LIMITED}: resource_limited[t];

# all other types of project (dispatchable and installable anywhere)
set PROJ_ANYWHERE 
  = LOAD_ZONES cross 
    setof {t in TECHNOLOGIES: not intermittent[t] and not resource_limited[t]} 
      (t, site_unspecified, orient_unspecified);

# some projects could be resource-limited but not intermittent (e.g., geothermal).
# solar troughs are intermittent but not resource limited
# so we union all the possibilities
set PROJECTS = 
  PROJ_ANYWHERE 
  union PROJ_INTERMITTENT
  union PROJ_RESOURCE_LIMITED;

# the set of all dispatchable projects (i.e., non-intermittent)
set PROJ_DISPATCH = (PROJECTS diff PROJ_INTERMITTENT);

# sets derived from site-specific tables, help keep projects distinct
set SITES = setof {(z, t, s, o) in PROJECTS} (s);
set ORIENTATIONS = setof {(z, t, s, o) in PROJECTS} (o);

# distance to connect a new project to an interconnect point on the grid, in km.
# a line of this length will need to be built, at the standard transmission line cost.
param connect_length_km {(z, t, s, o) in PROJECTS} >= 0 default 0;

# cost of grid upgrades to support a new project, in dollars per peak kW.
# these are needed in order to deliver power from the interconnect point to
# the load center (or make it deliverable to other zones)
param connect_cost_per_kw {(z, t, s, o) in PROJECTS} >= 0 default 0;

##############################################
# Existing hydro plants (assumed impossible to build more, but these last forever)

# forced outage rate for hydroelectric dams
# this is used to de-rate the planned power production
param forced_outage_rate_hydro >= 0;

# round-trip efficiency for storing power via a pumped hydro system
param pumped_hydro_efficiency >= 0;

# annual cost for existing hydro plants (see notes in windsun.dat)
# it would be better to calculate this from the capital cost, fixed and variable O&M,
# but that introduces messy new parameters and doesn't add anything to the analysis
param hydro_annual_payment_per_mw >= 0;

# indexing sets for hydro data (read in along with data tables)
# (this should probably be monthly data, but this has equivalent effect,
# and doesn't require adding a month dataset and month <-> date links)
set PROJ_HYDRO_DATES dimen 3; # load_zone, site, date

# minimum, maximum and average flow (in average MW) at each dam, each day
# (note: we assume that the average dispatch for each day must come out at this average level,
# and flow will always be between minimum and maximum levels)
# maximum is based on plant size
# average is based on historical power production for each month
# for simple hydro, minimum flow is a fixed fraction of average flow (for now)
# for pumped hydro, minimum flow is a negative value, showing the maximum pumping rate
param avg_hydro_flow {PROJ_HYDRO_DATES};
param max_hydro_flow {PROJ_HYDRO_DATES};
param min_hydro_flow {PROJ_HYDRO_DATES};
check {(z, s, d) in PROJ_HYDRO_DATES}: 
  min_hydro_flow[z, s, d] <= avg_hydro_flow[z, s, d] <= max_hydro_flow[z, s, d];

# list of all hydroelectric projects (pumped or simple)
set PROJ_HYDRO = setof {(z, s, d) in PROJ_HYDRO_DATES} (z, s);

# pumped hydro projects (have negative minimum flows at some point),
# or any projects that should get individual-hour dispatch
# set PROJ_PUMPED_HYDRO = setof {(z, s, d) in PROJ_HYDRO_DATES} (z, s);
# the next two limits are equivalent (they give individual dispatch of all large hydro, and aggregated dispatch of small, baseload hydro)
# set PROJ_PUMPED_HYDRO = setof {(z, s, d) in PROJ_HYDRO_DATES: min_hydro_flow[z, s, d] < 0 or z="Northwest" or max_hydro_flow[z, s, d] >= 50} (z, s);
# set PROJ_PUMPED_HYDRO = setof {(z, s, d) in PROJ_HYDRO_DATES: min_hydro_flow[z, s, d] < 0.9999 * avg_hydro_flow[z, s, d]} (z, s);
set PROJ_PUMPED_HYDRO = setof {(z, s, d) in PROJ_HYDRO_DATES: min_hydro_flow[z, s, d] < 0 or z="Northwest" or max_hydro_flow[z, s, d] >= 100} (z, s);
# set PROJ_PUMPED_HYDRO = setof {(z, s, d) in PROJ_HYDRO_DATES: min_hydro_flow[z, s, d] < 0 or z="Northwest"} (z, s);

# model can fit in 32-bit cplex with installtrans fixed, or with individual dispatch only for hydro sites >= 100 MW. 
# it cannot fit if installtrans is free and sites between 50 and 100 MW are dispatched individually.

# simple hydro projects (everything else)
set PROJ_SIMPLE_HYDRO = PROJ_HYDRO diff PROJ_PUMPED_HYDRO;

# make sure the data tables have full, matching sets of data
check card(DATES symdiff setof {(z, s, d) in PROJ_HYDRO_DATES} (d)) = 0;
check card(PROJ_HYDRO_DATES) = card(PROJ_HYDRO) * card(DATES);
# this could be changed to 
# check card(PROJ_HYDRO_DATES symdiff (PROJ_HYDRO cross DATES)) = 0

#################
# simple hydro projects are dispatched on a linearized, aggregated basis in each zone
# the code below sets up parameters for this.

# maximum share of each day's "discretionary" hydro flow 
# (everything between the minimum_hydro_flow and the average_hydro_flow) 
# that can be dispatched in a single hour.
# Higher values will produce narrower, taller hydro dispatch schedules,
# but also more "baseload" hydro.

# TODO: convert discretionary hydro dispatch DispatchHydroShare[] and DispatchHydroShare_Reserve[]
# to be a flow rate in MW, whose sum is limited to (# samples per day) * (avg flow - min flow).
# In each hour, it would be limited to max_multiple_of_avg_discretionary_rate * (avg flow - min flow)
# (instead of [# samples per day] * [an arbitrary fraction of 1]).
# This will avoid having to sum (arbitrarily) to 1 and then multiply each hour's number by 24 * (avg - min),
# and will avoid putting the (# samples per day) in the hourly flow constraint.
# (wait till next time a full set of solutions is run, to avoid interfering with older saved solutions)
# MAYBE better than that: stick with percentages, but have them be percentages of the average discretionary
# flow rate, with a requirement that the average across all hours (instead of sum) is 1.

param max_hydro_dispatch_per_hour;

# minimum and maximum flow rates for each simple hydro facility,
# dispatched on a linearized, aggregated basis.
param min_hydro_dispatch {(z, s) in PROJ_SIMPLE_HYDRO, d in DATES} =
  max(
    # if the avg_hydro_flow is close to the max_hydro_flow for this site, then we need to increase the 
    # minimum flow rate, reducing the amount of  "discretionary" hydro, so that when max_hydro_dispatch_per_hour
    # is dispatched, it won't overshoot the max_hydro_flow for this site.
    # note: this term is just the solution to the reqmt that min + max_per_hour * 24 * (avg - min) <= max
    (max_hydro_dispatch_per_hour * 24 * avg_hydro_flow[z, s, d] - max_hydro_flow[z, s, d]) 
      / (max_hydro_dispatch_per_hour * 24 - 1),

    # in other cases, we just respect the lower flow limit for the site.
    min_hydro_flow[z, s, d]
  );
# make sure we'll never overshoot maximum allowed production
check {(z, s) in PROJ_SIMPLE_HYDRO, d in DATES}: 
  min_hydro_dispatch[z, s, d] 
  + max_hydro_dispatch_per_hour * (avg_hydro_flow[z, s, d] - min_hydro_dispatch[z, s, d]) * 24
    <= max_hydro_flow[z, s, d] * 1.001;

# pre-aggregate the available simple hydro supply for use in the satisfy_load constraint
param min_hydro_dispatch_all_sites {z in LOAD_ZONES, d in DATES} 
  = sum {(z, s) in PROJ_SIMPLE_HYDRO} min_hydro_dispatch[z, s, d];
param avg_hydro_dispatch_all_sites {z in LOAD_ZONES, d in DATES} 
  = sum {(z, s) in PROJ_SIMPLE_HYDRO} avg_hydro_flow[z, s, d];

#display
#  min_hydro_dispatch['Fresno','Balch__218',2337] + max_hydro_dispatch_per_hour * (avg_hydro_flow['Fresno','Balch__218',2337] - min_hydro_dispatch['Fresno','Balch__218',2337]) * 24,  max_hydro_flow['Fresno','Balch__218',2337];

###############################################
# Existing generators

# name of each plant
set EXISTING_PLANTS dimen 2;  # load zone, plant code

check {z in setof {(z, e) in EXISTING_PLANTS} (z)}: z in LOAD_ZONES;

# the size of the plant in MW
param ep_size_mw {EXISTING_PLANTS} >= 0;

# NOTE: most of the remaining per-plant data could be 
# stored on an aggregated basis in the generator_cost table,
# and then each plant could just specify a load zone and technology.
# However, individual plants would probably still need  a custom 
# heat rate, and maybe forced outage rate, 
# which would override the generic technology specification.

# type of fuel used by the plant
param ep_fuel {EXISTING_PLANTS} symbolic in FUELS;

# heat rate (in Btu/kWh)
param ep_heat_rate{EXISTING_PLANTS} >= 0;

# year when the plant was built (used to calculate annual capital cost and retirement date)
param ep_vintage {EXISTING_PLANTS} >= 0;

# life of the plant (age when it must be retired)
param ep_max_age_years {EXISTING_PLANTS} >= 0;

# overnight cost of the plant ($/kW)
param ep_overnight_cost {EXISTING_PLANTS} >= 0;

# fixed O&M ($/kW-year)
param ep_fixed_o_m {EXISTING_PLANTS} >= 0;

# variable O&M ($/MWh)
param ep_variable_o_m {EXISTING_PLANTS} >= 0;

# fraction of the time when a plant will be unexpectedly unavailable
param ep_forced_outage_rate {EXISTING_PLANTS} >= 0, <= 1;

# fraction of the time when a plant must be taken off-line for maintenance
# note: this is also used for plants that only run part time
# e.g., a baseload-type plant with 97% reliability but 80% capacity factor
param ep_scheduled_outage_rate {EXISTING_PLANTS} >= 0, <= 1;

# does the generator run at its full capacity all year?
param ep_baseload {EXISTING_PLANTS} binary;

# is the generator part of a cogen facility (used for reporting)?
param ep_cogen {EXISTING_PLANTS} binary;

###############################################
# Transmission lines

# cost to build a transmission line, per mw of capacity, per km of distance
# (assumed linear and can be added in small increments!)
param transmission_cost_per_mw_km >= 0;

# (sunk) carrying cost for existing transmission lines
param transmission_cost_per_existing_mw_km >= 0 default transmission_cost_per_mw_km;

# retirement age for transmission lines
param transmission_max_age_years >= 0;

# forced outage rate for transmission lines, used for probabilistic dispatch(!)
param transmission_forced_outage_rate >= 0;

# x and y coordinates of center of each load zone, in meters
param load_zone_x {LOAD_ZONES};
param load_zone_y {LOAD_ZONES};

# possible transmission lines are listed in advance;
# these include all possible combinations of load_zones, with no double-counting
# The model could be simplified by only allowing lines to be built between neighboring zones.
set TRANS_LINES in {LOAD_ZONES, LOAD_ZONES};

# length of each transmission line
param transmission_length_km {TRANS_LINES};

# delivery efficiency on each transmission line
param transmission_efficiency {TRANS_LINES};

# the rating of existing lines in MW (can be different for the two directions)
param existing_transmission_from {TRANS_LINES} >= 0 default 0;
param existing_transmission_to {TRANS_LINES} >= 0 default 0;

# unique ID for each transmission line, used for reporting results
param tid {TRANS_LINES};

# parameters for local transmission and distribution from the large-scale network to distributed loads
param local_td_max_age_years >= 0;
param local_td_annual_payment_per_mw >= 0;


###################
#
# Financial data and calculations
#

# the year to which all costs should be discounted
param base_year >= 0;

# annual rate (real) to use to discount future costs to current year
param discount_rate;

# required rates of return (real) for generator and transmission investments
# may differ between generator types, and between generators and transmission lines
param finance_rate {TECHNOLOGIES} >= 0;
param transmission_finance_rate >= 0;

# cost of carbon emissions ($/ton), e.g., from a carbon tax
# can also be set negative to drive renewables out of the system
param carbon_cost;

# penalty charge assigned for unserved load in any zone in any hour
# (this should be set so high that there is no unserved load, but it could be
# set to a "realistic" number to assess the value of load shedding.)
# The main reason for including this in the model is to ensure that any
# investment plan is "feasible," even if it doesn't include enough plants
# to satisfy the system load.
param unsatisfied_load_penalty >= 0;

# annual fuel price forecast
param fuel_cost {YEARS, FUELS} default 0, >= 0;
# this defaults to zero (for renewables), but we need to make sure 
# that if a non-zero values are given for any year, they are given for all years
check {y in YEARS, f in setof {y1 in YEARS, f1 in FUELS: fuel_cost[y1, f1] > 0} (f1)}: fuel_cost[y, f] > 0;

# carbon content (tons) per million Btu of each fuel
param carbon_content {FUELS} default 0, >= 0;

# Calculate discounted fixed and variable costs for each technology and vintage

# For now, all hours in each study period use the fuel cost 
# from the year when each study period started.
# This is because we don't want artificially strong run-ups in fuel prices
# between the beginning and end of each study period as a result of the long intervals
# needed to make it solvable.
# This could be updated to use fuel costs that vary by month,
# or for an hourly model, it could interpolate between annual forecasts 
# (see versions of this model from before 11/27/07 for code to do that).
param fuel_cost_hourly {f in FUELS, h in HOURS} := fuel_cost[floor(period[h]), f];

# weighting factors for annual and hourly costs.
# These account for the number of hours represented by each sample, 
# or number of years during each study period. They also discount costs
# that are spread across each study period up to the start of the study
# period. Finally, they discount from the start of each study period
# to the base year.

param annual_cost_weight {p in PERIODS} = 
  (1-(1/(1+discount_rate)^(years_per_period)))/discount_rate
  * 1 / (1 + discount_rate)^(p - base_year);

param hourly_cost_weight {h in HOURS} =
  annual_cost_weight[period[h]] * hours_in_sample[h]/years_per_period;

##########
# calculate costs for new plants

# apply projected annual real cost changes to each technology,
# to get the capital, fixed and variable costs if it is installed 
# at each possible vintage date

# first, the capital cost of the plant and any 
# interconnecting lines and grid upgrades
# (all costs are in $/kW)
param capital_cost_proj {(z, t, s, o) in PROJECTS, v in VINTAGE_YEARS} = 
  capital_cost_by_vintage[t, v]
  + connect_length_km[z, t, s, o] * transmission_cost_per_mw_km / 1000
  + connect_cost_per_kw_generic[t] 
  + connect_cost_per_kw[z, t, s, o]
; 

param fixed_cost_proj {t in TECHNOLOGIES, v in VINTAGE_YEARS} = 
  fixed_o_m[t];
# earlier version assumed that fixed_costs changed exponentially over time; this version assumes flat fixed O&M costs

# earlier versions also assumed that variable costs declined for future vintages,
# but this version does not, because the changes were minor, hard to support,
# and required separate dispatch decisions for every vintage of every technology,
# which needlessly expands the model.

# annual revenue that will be needed to cover the capital cost
param capital_cost_annual_payment {(z, t, s, o) in PROJECTS, v in VINTAGE_YEARS} = 
  finance_rate[t] * (1 + 1/((1+finance_rate[t])^max_age_years[t]-1)) * capital_cost_proj[z, t, s, o, v];

# date when a plant of each type and vintage will stop being included in the simulation
# note: if it would be expected to retire between study periods,
# it is kept running (and annual payments continue to be made) 
# until the end of that period. This avoids having artificial gaps
# between retirements and starting new plants.
param project_end_year {t in TECHNOLOGIES, v in VINTAGE_YEARS} =
  min(end_year, v+ceil(max_age_years[t]/years_per_period)*years_per_period);

# finally, convert the payments into hourly values
# (these must be paid during all periods when the plant is available)
# Reported costs are in $/kW, but we need $/MW, so we multiply by 1000.
param fixed_cost_per_hour {(z, t, s, o) in PROJECTS, v in VINTAGE_YEARS} =
  (capital_cost_annual_payment[z,t,s,o,v] + fixed_cost_proj[t,v]) * 1000 / hours_per_year;
  
# all variable costs ($/MWh) for generating a MWh of electricity in some
# future hour, using a particular technology and vintage, 
# these include O&M, fuel, carbon tax
# note: we divide heat_rate by 1000 to go from Btu/kWh to MBtu/MWh
# (this used to vary by vintage to allow for changing variable costs, but not anymore)
param variable_cost_per_mwh {t in TECHNOLOGIES, h in HOURS} =
    variable_o_m[t] 
    + heat_rate[t]/1000 * fuel_cost_hourly[fuel[t], h];

# this can be pre-calculated, but it's easier to include it directly in the objective function
# so it can easily be stripped down to get total carbon for reporting
#param carbon_cost_per_mwh {t in TECHNOLOGIES} = 
#     heat_rate[t]/1000 * carbon_content[fuel[t]] * carbon_cost;

########
# now get costs for existing projects on similar terms

# year when the plant will be retired
# this is rounded up to the end of the study period when the retirement would occur,
# so power is generated and capital & O&M payments are made until the end of that period.
# note: this is set as a default value rather than a direct assignment, so that it can be changed
# if plants need to be forced not to retire.
param ep_end_year {(z, e) in EXISTING_PLANTS} default
  min(end_year, start_year+ceil((ep_vintage[z, e]+ep_max_age_years[z, e]-start_year)/years_per_period)*years_per_period);

# annual revenue that is needed to cover the capital cost (per kw)
# TODO: find a better way to specify the finance rate applied to existing projects
# for now, we just assume it's the same as a new CCGT plant
param ep_capital_cost_annual_payment {(z, e) in EXISTING_PLANTS} = 
  finance_rate[tech_ccgt] * (1 + 1/((1+finance_rate[tech_ccgt])^ep_max_age_years[z, e]-1)) * ep_overnight_cost[z, e];

# Hourly share of capital costs during the remaining life of the plant
# Reported costs are in $/kW, but we need $/MW, so we multiply by 1000.
param ep_capital_cost_per_hour {(z, e) in EXISTING_PLANTS} =
  ep_capital_cost_annual_payment[z, e] * 1000 / hours_per_year;

# Hourly share of fixed O&M costs (per MW) during the remaining life of the plant
# These can be avoided by not operating the plant during a given period
param ep_fixed_cost_per_hour {(z, e) in EXISTING_PLANTS} =
  ep_fixed_o_m[z, e] * 1000 / hours_per_year;

# all variable costs ($/MWh) for generating a MWh of electricity in some
# future hour, from each existing project, discounted to the reference year
# note: we divide heat_rate by 1000 to go from Btu/kWh to MBtu/MWh
param ep_variable_cost_per_mwh {(z, e) in EXISTING_PLANTS, h in HOURS} =
    ep_variable_o_m[z, e] 
    + ep_heat_rate[z, e]/1000 * fuel_cost_hourly[ep_fuel[z, e], h];

# this can be pre-calculated, but it's easier to include it directly in the objective function
# so it can easily be stripped down to get total carbon for reporting
#param ep_carbon_cost_per_mwh {(z, e) in EXISTING_PLANTS} = 
#    ep_heat_rate[z, e]/1000 * carbon_content[ep_fuel[z, e]] * carbon_cost;


########
# now get costs per MW for transmission lines on similar terms

# cost per MW for transmission lines
# TODO: use a transmission_annual_cost_change factor to make this vary between vintages
param transmission_annual_payment {(z1, z2) in TRANS_LINES, v in VINTAGE_YEARS} = 
  transmission_finance_rate * (1 + 1/((1+transmission_finance_rate)^transmission_max_age_years-1)) 
  * transmission_cost_per_mw_km * transmission_length_km[z1, z2];

# date when a when a transmission line built of each vintage will stop being included in the simulation
# note: if it would be expected to retire between study periods,
# it is kept running (and annual payments continue to be made).
param transmission_end_year {v in VINTAGE_YEARS} =
  min(end_year, v+ceil(transmission_max_age_years/years_per_period)*years_per_period);

# cost per MW of capacity per calendar hour
param transmission_cost_per_mw_per_hour {(z1, z2) in TRANS_LINES, v in VINTAGE_YEARS} =
  transmission_annual_payment[z1, z2, v] / hours_per_year;

param transmission_cost_per_existing_mw_per_hour {(z1, z2) in TRANS_LINES} =
  transmission_cost_per_mw_per_hour[z1, z2, first(PERIODS)] * transmission_cost_per_existing_mw_km / transmission_cost_per_mw_km;

# date when local T&D infrastructure of each vintage will stop being included in the simulation
# note: if it would be expected to retire between study periods,
# it is kept running (and annual payments continue to be made).
param local_td_end_year {v in VINTAGE_YEARS} =
  min(end_year, v+ceil(local_td_max_age_years/years_per_period)*years_per_period);

# cost per MW for local T&D
# note: instead of bringing in an annual payment directly (above), we could calculate it as
# = local_td_finance_rate * (1 + 1/((1+local_td_finance_rate)^local_td_max_age_years-1)) 
#  * local_td_real_cost_per_mw; # (if that were known)
param local_td_cost_per_mw_per_hour {v in VINTAGE_YEARS} = 
  local_td_annual_payment_per_mw / hours_per_year;

######
# total cost of existing hydro plants (including capital and O&M)
# note: it would be better to handle these costs more endogenously.
# for now, we assume the nameplate capacity of each plant is equal to its peak allowed output.

# the total cost per MW for existing hydro plants
# (the discounted stream of annual payments over the whole study)
param hydro_cost_per_mw_per_hour = 
  hydro_annual_payment_per_mw / hours_per_year;
# make a guess at the nameplate capacity of all existing hydro
param hydro_total_capacity = 
  sum {(z, s) in PROJ_HYDRO} (max {(z, s, d) in PROJ_HYDRO_DATES} max_hydro_flow[z, s, d]);

#######
# Supply curve for interruptible load (in discounted-cost terms)

# This stairstepped curve is specified by a list of marginal costs 
# corresponding to various levels of usage of interruptible laod
# (the marginal cost rises as we use more of it)
# Each pair of marginal cost and usage level is known as a "breakpoint"

# indexing list of the segments of the interruptible load cost curve
# this includes one element for the right edge of each segment of the cost curve
set INTERRUPTIBLE_LOAD_BREAKPOINTS ordered = 1 .. interruptible_load_cost_segment_count;

# list of the percentages of peak load for each cost curve breakpoint
# (e.g., interruptible load equal to 0.01, 0.02, ... * peak load for the zone)
param interruptible_load_breakpoint_share {bp in INTERRUPTIBLE_LOAD_BREAKPOINTS}
  = bp * interruptible_load_max_share/interruptible_load_cost_segment_count;

# corresponding amounts of interruptible load (in MW) in each load zone
param interruptible_load_breakpoint_mw {z in LOAD_ZONES, p in PERIODS, bp in INTERRUPTIBLE_LOAD_BREAKPOINTS}
  = interruptible_load_breakpoint_share[bp] * max {h in HOURS: period[h]=p} system_load_fixed[z, h];

# calculate the marginal cost per MW of interruptible load between each breakpoint.
# (costs are for additional capacity up to and including that breakpoint)
# For now, we assume the marginal cost increases linearly as the percentage of interruptible load increases.
# (In future, it would be possible to create different stairstepped supply curves.)
# note: this creates a stairstep supply curve whose right edge matches 
# with a straightline supply curve with the same average slope. That way, the model will never
# use more interruptible load than is available at each cost point. But this does tend to 
# overstate the total costs, compared to a centered stairstep supply curve, at least for a
# pay-as-bid type auction or social welfare calculation where producer surplus is counted as a benefit. 
# (On the other hand, if the breakpoints are close together, this error will be small, and 
# in fact the cost of interruptible load will be much higher in a uniform-price auction.)
param interruptible_load_cost_slope
  {z in LOAD_ZONES, p in PERIODS, bp in INTERRUPTIBLE_LOAD_BREAKPOINTS} =
  interruptible_load_cost_per_kw_year_per_percent_peak_load * 1000
  * interruptible_load_breakpoint_share[bp] * 100
  * annual_cost_weight[p];

# Total cost of developing various amounts of interruptible load.
# This is useful for the linear constraint that keeps total costs at or above the appropriate level.
param interruptible_load_total_cost {z in LOAD_ZONES, p in PERIODS, bp in INTERRUPTIBLE_LOAD_BREAKPOINTS} =
  sum {bp2 in INTERRUPTIBLE_LOAD_BREAKPOINTS: bp2 <= bp}
    interruptible_load_cost_slope[z, p, bp2] * 
      (interruptible_load_breakpoint_mw[z, p, bp2] - if ord(bp2)=1 then 0 else interruptible_load_breakpoint_mw[z, p, prev(bp2)]);

#######
# Demand curve for electricity on an annual basis,
# in MWh and dollar terms, specific to each load zone and period, with discounting.

# The demand curve for each load zone needs to show marginal benefits in dollars for each extra
# unit of electricity delivered. The electricity could be expressed in % of base (which is how
# the overall demand curve is expressed), or in terms of peak MW served or total MWh delivered.
# It would be mathematically simpler to use the % of base, but then the marginal prices are only
# "true" for a particular base level of demand. If the prices are expressed per MWh delivered,
# then they will be more robust if we change the base quantity of electricity demanded, and they
# will be easier to interpret (e.g., "the marginal value of delivering 1 MWh spread through the year
# with the normal load pattern for Fresno is $89" instead of "if we raise the year-round supply of 
# power in Fresno by 1% it will yield $92012312 worth of benefits"). 
# So I express the amount of power demanded in MWh, and calculate the cost of delivering various 
# numbers of MWh in each load zone. 
# (this requires multiplying and dividing by annual_demand_quantity_base_mwh[z,p] in various places)

# calculate the base-case power demand per year in each zone, in MWh 
param annual_demand_quantity_base_mwh {z in LOAD_ZONES, p in PERIODS} = 
  sum {h in HOURS: period[h] = p} system_load_fixed[z, h] * hours_in_sample[h] / years_per_period;
# find the MWh levels corresponding to breakpoints on the demand curve
param annual_demand_quantity_mwh {z in LOAD_ZONES, p in PERIODS, bp in ANNUAL_DEMAND_BREAKPOINTS} = 
  annual_demand_quantity_vs_base[bp] * annual_demand_quantity_base_mwh[z, p];

# calculate the marginal benefit (dollars per MWh, in present-value terms) of 
# delivering power when the total annual system load is at various levels.
# (benefits are for additional power production when the total demand is at or beyond each breakpoint)
param annual_demand_benefit_slope
  {z in LOAD_ZONES, p in PERIODS, bp in ANNUAL_DEMAND_BREAKPOINTS} =
  annual_demand_price_vs_base[bp] * annual_demand_price_base[z] * annual_cost_weight[p];

# Total benefit (in dollars) of delivering various amounts of annual power (in MWh)
# This is the integral of the price vs power supply curve up to each breakpoint.
# It is useful for the linear constraint that keeps total costs at or above the appropriate level.
# note: we don't know the total value of supplying power up to the first breakpoint, so we just assume zero.
# The marginal values between breakpoints are what actually matter, but this means the objective function
# cannot be interpreted as reporting the "true" net benefit of generating power.
param annual_demand_benefit_total {z in LOAD_ZONES, p in PERIODS, bp in ANNUAL_DEMAND_BREAKPOINTS} =
  if ord(bp) = 1 then 0 else
  annual_demand_benefit_total[z, p, prev(bp)] 
    + annual_demand_benefit_slope[z, p, prev(bp)] * 
      (annual_demand_quantity_mwh[z, p, bp] - annual_demand_quantity_mwh[z, p, prev(bp)]);

######
# "discounted" system load, for use in calculating levelized cost of power.
param system_load_discounted = 
  sum {z in LOAD_ZONES, d in DATES, h in HOURS: date[h]=d} 
    hourly_cost_weight[h] * (system_load_fixed[z,h] + system_load_moveable[z,d]);

##################
# specific sets that are used often
# some of these are also important to the logic of the model,
# i.e., we don't consider using projects during periods that are beyond their retirement year
# (those post-retirement years are simply excluded from the indexing set)

# project-vintage combinations that can be installed
set PROJECT_VINTAGES = setof {(z, t, s, o) in PROJECTS, v in VINTAGE_YEARS: v >= min_vintage_year[t]} (z, t, s, o, v);

# project-vintage-hour combinations that can be operated (and for which capital and fixed-cost payments must be made)
set PROJ_VINTAGE_HOURS := 
  {(z, t, s, o) in PROJECTS, v in VINTAGE_YEARS, h in HOURS: v >= min_vintage_year[t] and v <= period[h] < project_end_year[t, v]};

# technology-site-vintage-hour combinations for dispatchable projects
# (i.e., all the project-vintage combinations that are still active in a given hour of the study)
set PROJ_DISPATCH_VINTAGE_HOURS := 
  {(z, t, s, o) in PROJ_DISPATCH, v in VINTAGE_YEARS, h in HOURS: v >= min_vintage_year[t] and v <= period[h] < project_end_year[t, v]};

# technology-site-vintage-hour combinations for intermittent (non-dispatchable) projects
set PROJ_INTERMITTENT_VINTAGE_HOURS := 
  {(z, t, s, o) in PROJ_INTERMITTENT, v in VINTAGE_YEARS, h in HOURS: v >= min_vintage_year[t] and v <= period[h] < project_end_year[t, v]};

# plant-period combinations when existing plants can run
# these are the times when a decision must be made about whether a plant will be kept available for the year
# or mothballed to save on fixed O&M (or fuel, for baseload plants)
# note: something like this could be added later for early retirement of new plants too
set EP_PERIODS :=
  {(z, e) in EXISTING_PLANTS, p in PERIODS: ep_vintage[z, e] <= p < ep_end_year[z, e]};

# plant-hour combinations when existing non-baseload plants can be dispatched
set EP_DISPATCH_HOURS :=
  {(z, e) in EXISTING_PLANTS, h in HOURS: not ep_baseload[z, e] and ep_vintage[z, e] <= period[h] < ep_end_year[z, e]};

# plant-period combinations when existing baseload plants can run
set EP_BASELOAD_PERIODS :=
  {(z, e, p) in EP_PERIODS: ep_baseload[z, e]};

# trans_line-vintage-hour combinations for which dispatch decisions must be made
set TRANS_VINTAGE_HOURS := 
  {(z1, z2) in TRANS_LINES, v in VINTAGE_YEARS, h in HOURS: v <= period[h] < transmission_end_year[v]};

# local_td-vintage-hour combinations which must be reconciled
set LOCAL_TD_HOURS := 
  {z in LOAD_ZONES, v in VINTAGE_YEARS, h in HOURS: v <= period[h] < local_td_end_year[v]};


#### VARIABLES ####

# number of MW to install in each project at each date (vintage)
var InstallGen {PROJECT_VINTAGES} >= 0;

# number of MW to generate from each project, in each hour
var DispatchGen {PROJ_DISPATCH, HOURS} >= 0;

# number of MW of moveable load to serve in each hour
var DispatchSystemLoad {LOAD_ZONES, HOURS} >= 0;

# number of MW generated by intermittent renewables
# this is not a decision variable, but is useful for reporting
# (well, it would be useful for reporting, but it takes 63 MB of ram for 
# 240 hours x 2 vintages and grows proportionally to that product)
#var IntermittentOutput {(z, t, s, o, v, h) in PROJ_INTERMITTENT_VINTAGE_HOURS} 
#   = (1-forced_outage_rate[t]) * cap_factor[z, t, s, o, h] * InstallGen[z, t, s, o, v];

# share of existing plants to operate during each study period.
# this should be a binary variable, but it's interesting to see 
# how the continuous form works out
var OperateEPDuringYear {EP_PERIODS} >= 0, <= 1;

# number of MW to generate from each existing dispatchable plant, in each hour
var DispatchEP {EP_DISPATCH_HOURS} >= 0;

# number of MW to install in each transmission corridor at each vintage
var InstallTrans {TRANS_LINES, VINTAGE_YEARS} >= 0;

# number of MW to transmit through each transmission corridor in each hour
var DispatchTransTo {TRANS_LINES, HOURS} >= 0;
var DispatchTransFrom {TRANS_LINES, HOURS} >= 0;
var DispatchTransTo_Reserve {TRANS_LINES, HOURS} >= 0;
var DispatchTransFrom_Reserve {TRANS_LINES, HOURS} >= 0;

# amount of local transmission and distribution capacity
# (to carry peak power from transmission network to distributed loads)
var InstallLocalTD {LOAD_ZONES, VINTAGE_YEARS} >= 0;

# amount of pumped hydro to store and dispatch during each hour
# note: the amount "stored" is the number of MW that can be generated using
# the water that is stored, 
# so it takes 1/pumped_hydro_efficiency MWh to store 1 MWh
var StorePumpedHydro {PROJ_PUMPED_HYDRO, HOURS} >= 0;
var DispatchPumpedHydro {PROJ_PUMPED_HYDRO, HOURS} >= 0;
var StorePumpedHydro_Reserve {PROJ_PUMPED_HYDRO, HOURS} >= 0;
var DispatchPumpedHydro_Reserve {PROJ_PUMPED_HYDRO, HOURS} >= 0;

# simple hydro is dispatched on an aggregated basis, using a schedule that shows the
# amount of discretionary hydro to dispatch during each study period, in each zone,
# season (Jan-Mar, Apr-Jun, etc.) and hour
var HydroDispatchShare {PERIODS, LOAD_ZONES, SEASONS_OF_YEAR, HOURS_OF_DAY} >= 0;
var HydroDispatchShare_Reserve {PERIODS, LOAD_ZONES, SEASONS_OF_YEAR, HOURS_OF_DAY} >= 0;

# the total amount of generic demand response that will be developed
#var AcceptDemandResponseMW >= 0;

# amount of interruptible load used in each load zone during each period (in MW)
var AcceptInterruptibleLoad {z in LOAD_ZONES, p in PERIODS} >= 0;
var InterruptibleLoadCost {z in LOAD_ZONES, p in PERIODS} >= 0;

# amount of annual demand satisfied in each load zone during each period (in MW)
var ClearAnnualDemand {z in LOAD_ZONES, p in PERIODS} >= 0 default annual_demand_quantity_base_mwh[z, p];
var AnnualDemandBenefit {z in LOAD_ZONES, p in PERIODS} >= 0;

# amount of load to be left unsatisfied in each load zone during each hour (in MW)
var UnsatisfiedLoad {z in LOAD_ZONES, h in HOURS} >= 0;

#### OBJECTIVES ####

# total cost of power, including carbon adder
# TODO: maybe break this down into subcomponents (fuel, carbon, plants, etc, possibly by period)
# to make reuse/reporting by other scripts easier (unfortunately, ampl doesn't handle defined variables
# well enough to allow this)

# note: since the hours are non-chronological samples within each study period,
# they are all discounted by the same factor (i.e., each sample ("hour") is assumed to
# represent hours that could occur anytime during the full investment period)

minimize Power_Cost:
  sum {p in PERIODS, h in HOURS: period[h]=p} hourly_cost_weight[h] * (
      sum {(z, t, s, o, v, h) in PROJ_VINTAGE_HOURS} 
        InstallGen[z, t, s, o, v] * fixed_cost_per_hour[z, t, s, o, v]
    + sum {(z, t, s, o) in PROJ_DISPATCH} 
        DispatchGen[z, t, s, o, h] * (variable_cost_per_mwh[t, h] + heat_rate[t]/1000 * carbon_content[fuel[t]] * carbon_cost)
    + sum {(z, e, p) in EP_PERIODS} ep_size_mw[z, e] * ep_capital_cost_per_hour[z, e]
    + sum {(z, e, p) in EP_PERIODS} 
        OperateEPDuringYear[z, e, p] * ep_size_mw[z, e] * ep_fixed_cost_per_hour[z, e]
    + sum {(z, e, p) in EP_BASELOAD_PERIODS}
        OperateEPDuringYear[z, e, p] * (1-ep_forced_outage_rate[z, e]) * (1-ep_scheduled_outage_rate[z, e]) * ep_size_mw[z, e] 
        * (ep_variable_cost_per_mwh[z, e, h] + ep_heat_rate[z, e]/1000 * carbon_content[ep_fuel[z, e]] * carbon_cost)
    + sum {(z, e, h) in EP_DISPATCH_HOURS}
        DispatchEP[z, e, h]
        * (ep_variable_cost_per_mwh[z, e, h] + ep_heat_rate[z, e]/1000 * carbon_content[ep_fuel[z, e]] * carbon_cost)
    + hydro_cost_per_mw_per_hour * hydro_total_capacity
    + sum {(z1, z2) in TRANS_LINES, v in VINTAGE_YEARS: v <= p} 
        InstallTrans[z1, z2, v] * transmission_cost_per_mw_per_hour[z1, z2, v]
    + sum {(z1, z2) in TRANS_LINES} 
        transmission_cost_per_existing_mw_per_hour[z1, z2] * (existing_transmission_from[z1, z2] + existing_transmission_to[z1, z2])/2
    + sum {z in LOAD_ZONES, v in VINTAGE_YEARS: v <= p}
        InstallLocalTD[z, v] * local_td_cost_per_mw_per_hour[v]
    + sum {z in LOAD_ZONES} UnsatisfiedLoad[z, h] * unsatisfied_load_penalty
  )
  # TODO: the following two should be discounted (?) and incorporated into the main objective function.
  # i.e., without discounting, the model compares discounted future costs (fuel & capital) to an undiscounted cost for load reductions?
  + sum {z in LOAD_ZONES, p in PERIODS} InterruptibleLoadCost[z, p]
  - sum {z in LOAD_ZONES, p in PERIODS} AnnualDemandBenefit[z, p]
  ;

# this alternative objective is used to reduce transmission flows to
# zero in one direction of each pair, and to minimize needless flows
# around loops, or shipping of unneeded power to neighboring zones, 
# so it is more clear where surplus power is being generated
minimize Transmission_Usage:
  sum {(z1, z2) in TRANS_LINES, h in HOURS} 
    (DispatchTransTo[z1, z2, h] + DispatchTransFrom[z1, z2, h]);


#### CONSTRAINTS ####

# system needs to meet the load in each load zone in each hour
# note: power is deemed to flow from z1 to z2 if positive, reverse if negative
subject to Satisfy_Load {z in LOAD_ZONES, h in HOURS}:

  # new dispatchable projects
  (sum {(z, t, s, o) in PROJ_DISPATCH} DispatchGen[z, t, s, o, h])

  # output from new intermittent projects
  + (sum {(z, t, s, o, v, h) in PROJ_INTERMITTENT_VINTAGE_HOURS} 
      (1-forced_outage_rate[t]) * cap_factor[z, t, s, o, h] * InstallGen[z, t, s, o, v])

  # existing baseload plants
  + sum {(z, e, p) in EP_BASELOAD_PERIODS: p=period[h]} 
      (OperateEPDuringYear[z, e, p] * (1-ep_forced_outage_rate[z, e]) * (1-ep_scheduled_outage_rate[z, e]) * ep_size_mw[z, e])
  # existing dispatchable plants
  + sum {(z, e, h) in EP_DISPATCH_HOURS} DispatchEP[z, e, h]

  # pumped hydro, de-rated to reflect occasional unavailability of the hydro plants
  + (1 - forced_outage_rate_hydro) * (sum {(z, s) in PROJ_PUMPED_HYDRO} DispatchPumpedHydro[z, s, h])
  - (1 - forced_outage_rate_hydro) * (1/pumped_hydro_efficiency) * 
      (sum {(z, s) in PROJ_PUMPED_HYDRO} StorePumpedHydro[z, s, h])
  # simple hydro, dispatched using the season-hour schedules chosen above
  # also de-rated to reflect occasional unavailability
  + (1 - forced_outage_rate_hydro) * 
    (min_hydro_dispatch_all_sites[z, date[h]] 
       + HydroDispatchShare[period[h], z, season_of_year[h], hour_of_day[h]]
         * (avg_hydro_dispatch_all_sites[z, date[h]] - min_hydro_dispatch_all_sites[z, date[h]]) * 24)

  # transmission into and out of the zone
  + (sum {(z, z2) in TRANS_LINES} (transmission_efficiency[z, z2] * DispatchTransTo[z, z2, h] - DispatchTransFrom[z, z2, h]))
  - (sum {(z1, z) in TRANS_LINES} (DispatchTransTo[z1, z, h] - transmission_efficiency[z1, z] * DispatchTransFrom[z1, z, h]))

  # load can be shed, with a corresponding penalty charge 
  # (this is usually set so high it is avoided, but it ensures that any investment plan is feasible)
  + UnsatisfiedLoad[z, h]

 >= system_load_fixed[z, h] * ClearAnnualDemand[z, period[h]]/max(annual_demand_quantity_base_mwh[z, period[h]], 1e-6)
    + DispatchSystemLoad[z, h];
# note: sometimes the base annual demand could be 0, so we set it to an arbitrarily small number to avoid dividing 0/0.

# same on a reserve basis
# note: these are not prorated by forced outage rate, because that is incorporated in the reserve margin
# It is also assumed that moveable load can be shed as needed, so it is not counted here either.
# Interruptible loads are assumed to reduce the load requirements for reserve margin also.
# -- this is only applied to the peak day
subject to Satisfy_Load_Reserve {z in LOAD_ZONES, h in HOURS: hours_in_sample[h]<100}:

  # new dispatchable capacity
  (sum {(z, t, s, o, v, h) in PROJ_DISPATCH_VINTAGE_HOURS} InstallGen[z, t, s, o, v])

  # output from new intermittent projects
  + (sum {(z, t, s, o, v, h) in PROJ_INTERMITTENT_VINTAGE_HOURS} 
      cap_factor[z, t, s, o, h] * InstallGen[z, t, s, o, v])

  # existing baseload plants
  + sum {(z, e, p) in EP_BASELOAD_PERIODS: p=period[h]} 
      (OperateEPDuringYear[z, e, p] * (1-ep_scheduled_outage_rate[z, e]) * ep_size_mw[z, e])
  # existing dispatchable capacity
  + sum {(z, e, h) in EP_DISPATCH_HOURS} OperateEPDuringYear[z, e, period[h]] * ep_size_mw[z, e]

  # pumped hydro
  + (sum {(z, s) in PROJ_PUMPED_HYDRO} DispatchPumpedHydro_Reserve[z, s, h])
  - (1/pumped_hydro_efficiency) * 
      (sum {(z, s) in PROJ_PUMPED_HYDRO} StorePumpedHydro_Reserve[z, s, h])
  # simple hydro, dispatched using the season-hour schedules chosen above
  + (min_hydro_dispatch_all_sites[z, date[h]] 
       + HydroDispatchShare_Reserve[period[h], z, season_of_year[h], hour_of_day[h]]
         * (avg_hydro_dispatch_all_sites[z, date[h]] - min_hydro_dispatch_all_sites[z, date[h]]) * 24)

  # transmission into and out of the zone
  + (sum {(z, z2) in TRANS_LINES} (transmission_efficiency[z, z2] * DispatchTransTo_Reserve[z, z2, h] - DispatchTransFrom_Reserve[z, z2, h]))
  - (sum {(z1, z) in TRANS_LINES} (DispatchTransTo_Reserve[z1, z, h] - transmission_efficiency[z1, z] * DispatchTransFrom_Reserve[z1, z, h]))

  # interruptible load contributes to reserve margin, even though it doesn't save energy
  # it also gets extra credit because it doesn't need to be backed up with a reserve margin 
  # (i.e., it reduces load in the reserve margin calculation)
  + AcceptInterruptibleLoad[z, period[h]] * (1 + planning_reserve_margin)

  # load can be shed, with a corresponding penalty charge
  # (also reduces the need for reserve margins)
  + UnsatisfiedLoad[z, h] * (1 + planning_reserve_margin)

  >= system_load_fixed[z, h] * (1 + planning_reserve_margin) * ClearAnnualDemand[z, period[h]]/max(annual_demand_quantity_base_mwh[z, period[h]], 1e-6)
;


# total dispatch of moveable load on each day must sum to the pre-specified average value
# (this could be a >= constraint, but that would make spilling of renewable power harder to spot)
subject to Dispatch_MoveableLoad {z in LOAD_ZONES, d in DATES}:
  sum {h in HOURS: date[h]=d} hours_in_sample[h] * DispatchSystemLoad[z, h] = 
  sum {h in HOURS: date[h]=d} hours_in_sample[h] * system_load_moveable[z, d];

# pumped hydro dispatch for all hours of the day must be within the limits of the plant
# net flow of power (i.e., water) must also match the historical average
# TODO: find better historical averages that reflect net balance of generated and stored power,
#  because the values currently used are equal to sum(Dispatch - 1/efficiency * Storage)
subject to Maximum_DispatchPumpedHydro {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS}:
  DispatchPumpedHydro[z, s, h] <= max_hydro_flow[z, s, date[h]];
subject to Maximum_StorePumpedHydro {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS: min_hydro_flow[z, s, date[h]] < 0}:
  StorePumpedHydro[z, s, h] <= -min_hydro_flow[z, s, date[h]];
subject to Average_PumpedHydroFlow {(z, s) in PROJ_PUMPED_HYDRO, d in DATES}:
  sum {h in HOURS: date[h]=d} (DispatchPumpedHydro[z, s, h] - StorePumpedHydro[z, s, h]) * hours_in_sample[h] 
  <= sum {h in HOURS: date[h]=d} avg_hydro_flow[z, s, d] * hours_in_sample[h];
# extra rules to apply when non-pumped sites are also dispatched hourly
subject to Minimum_DispatchNonPumpedHydro {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS: min_hydro_flow[z, s, date[h]] >= 0}:
  DispatchPumpedHydro[z, s, h] >= min_hydro_flow[z, s, date[h]];
subject to Maximum_StoreNonPumpedHydro {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS: min_hydro_flow[z, s, date[h]] >= 0}:
  StorePumpedHydro[z, s, h] = 0;

# discretionary hydro dispatch for all hours of the day must sum to 1
# note: dispatch is deemed to happen no matter what (to respect flow constraints), 
# but energy supply is later de-rated by hydro forced outage rate
# note: if not all the hours of the day are modeled, then the ones that
# are modeled actually stand in for other ones as well (e.g., if we only
# model 8 hours in the day, then each of those represents 3 hours of
# hydro dispatch). It would be better to replace max_hydro_dispatch_per_hour with
# a new parameter, max_hydro_dispatch_multiple (=24 * max_hydro_dispatch_per_hour),
# then we would require simply that the average hydro dispatch come out to 1,
# instead of the weighted sum.
subject to Maximum_DispatchHydroShare
  {p in PERIODS, z in LOAD_ZONES, s in SEASONS_OF_YEAR}: 
    sum {h in HOURS_OF_DAY} HydroDispatchShare[p, z, s, h] * (24 / card(HOURS_OF_DAY)) <= 1;

# only part of the discretionary hydro can be dispatched in each hour of the day
subject to MaximumHourly_DispatchHydroShare
  {p in PERIODS, z in LOAD_ZONES, s in SEASONS_OF_YEAR, h in HOURS_OF_DAY}:
    0 <= HydroDispatchShare[p, z, s, h] <= max_hydro_dispatch_per_hour;

# same for reserve margin operation
subject to Maximum_DispatchPumpedHydro_Reserve {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS}:
  DispatchPumpedHydro_Reserve[z, s, h] <= max_hydro_flow[z, s, date[h]];
subject to Maximum_StorePumpedHydro_Reserve {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS: min_hydro_flow[z, s, date[h]] < 0}:
  StorePumpedHydro_Reserve[z, s, h] <= -min_hydro_flow[z, s, date[h]];
subject to Average_PumpedHydroFlow_Reserve {(z, s) in PROJ_PUMPED_HYDRO, d in DATES}:
  sum {h in HOURS: date[h]=d} (DispatchPumpedHydro_Reserve[z, s, h] - StorePumpedHydro_Reserve[z, s, h]) <= 
  sum {h in HOURS: date[h]=d} avg_hydro_flow[z, s, d];
subject to Minimum_DispatchNonPumpedHydro_Reserve {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS: min_hydro_flow[z, s, date[h]] >= 0}:
  DispatchPumpedHydro_Reserve[z, s, h] >= min_hydro_flow[z, s, date[h]];
subject to Maximum_StoreNonPumpedHydro_Reserve {(z, s) in PROJ_PUMPED_HYDRO, h in HOURS: min_hydro_flow[z, s, date[h]] >= 0}:
  StorePumpedHydro_Reserve[z, s, h] = 0;
subject to Maximum_DispatchHydroShare_Reserve
  {p in PERIODS, z in LOAD_ZONES, s in SEASONS_OF_YEAR}: sum {h in HOURS_OF_DAY} HydroDispatchShare_Reserve[p, z, s, h] <= 1;
subject to MaximumHourly_DispatchHydroShare_Reserve
  {p in PERIODS, z in LOAD_ZONES, s in SEASONS_OF_YEAR, h in HOURS_OF_DAY}:
    0 <= HydroDispatchShare_Reserve[p, z, s, h] <= max_hydro_dispatch_per_hour;


# system can only dispatch as much of each project as is EXPECTED to be available
# i.e., we only dispatch up to 1-forced_outage_rate, so the system will work on an expected-value basis
# (this is the base portfolio, more backup generators will be added later to get a lower year-round risk level)
subject to Maximum_DispatchGen 
  {(z, t, s, o) in PROJ_DISPATCH, h in HOURS}:
  DispatchGen[z, t, s, o, h] <= (1-forced_outage_rate[t]) * 
    sum {(z, t, s, o, v, h) in PROJ_DISPATCH_VINTAGE_HOURS} InstallGen[z, t, s, o, v];

# there are limits on total installations in certain projects
# TODO: adjust this to allow re-installing at the same site after retiring an earlier plant
# (not an issue if the simulation is too short to retire plants)
# or even allow forced retiring of earlier plants if new technologies are better
subject to Maximum_Resource {(z, t, s, o) in PROJ_RESOURCE_LIMITED}:
  sum {(z, t, s, o, v) in PROJECT_VINTAGES} InstallGen[z, t, s, o, v] <= max_capacity[z, t, s, o];

# existing dispatchable plants can only be used if they are operational this year
subject to EP_Operational
  {(z, e, h) in EP_DISPATCH_HOURS}: DispatchEP[z, e, h] <= 
      OperateEPDuringYear[z, e, period[h]] * (1-ep_forced_outage_rate[z, e]) * ep_size_mw[z, e];

# system can only use as much transmission as is expected to be available
# note: transmission up and down the line both enter positively,
# but the form of the model allows them to both be reduced or increased by a constant,
# so they will both be held low enough to stay within the installed capacity
# (if there were a variable cost of operating, one of them would always go to zero)
# a quick follow-up model run minimizing transmission usage will push one of these to zero.
# TODO: retire pre-existing transmission lines after transmission_max_age_years 
#   (this requires figuring out when they were first built!)
subject to Maximum_DispatchTransTo 
  {(z1, z2) in TRANS_LINES, h in HOURS}:
  DispatchTransTo[z1, z2, h] 
    <= (1-transmission_forced_outage_rate) * 
          (existing_transmission_to[z1, z2] + sum {(z1, z2, v, h) in TRANS_VINTAGE_HOURS} InstallTrans[z1, z2, v]);
subject to Maximum_DispatchTransFrom 
  {(z1, z2) in TRANS_LINES, h in HOURS}:
  DispatchTransFrom[z1, z2, h] 
    <= (1-transmission_forced_outage_rate) * 
          (existing_transmission_from[z1, z2] + sum {(z1, z2, v, h) in TRANS_VINTAGE_HOURS} InstallTrans[z1, z2, v]);
subject to Maximum_DispatchTrans_ReserveTo
  {(z1, z2) in TRANS_LINES, h in HOURS}:
  DispatchTransTo_Reserve[z1, z2, h] 
    <= (existing_transmission_to[z1, z2] + sum {(z1, z2, v, h) in TRANS_VINTAGE_HOURS} InstallTrans[z1, z2, v]);
subject to Maximum_DispatchTrans_ReserveFrom
  {(z1, z2) in TRANS_LINES, h in HOURS}:
  DispatchTransFrom_Reserve[z1, z2, h] 
    <= (existing_transmission_from[z1, z2] + sum {(z1, z2, v, h) in TRANS_VINTAGE_HOURS} InstallTrans[z1, z2, v]);

# make sure there's enough intra-zone transmission and distribution capacity
# to handle the net distributed loads
# note: interruptible load is left out of this equation, 
# because it is not likely to be called upon just to relieve local T&D congestion.
subject to Maximum_LocalTD 
  {z in LOAD_ZONES, h in HOURS}:
  system_load_fixed[z, h] * ClearAnnualDemand[z, period[h]]/max(annual_demand_quantity_base_mwh[z, period[h]], 1e-6)
    + DispatchSystemLoad[z,h]
    - UnsatisfiedLoad[z, h]
    - (sum {(z, t, s, o, v, h) in PROJ_INTERMITTENT_VINTAGE_HOURS: t=tech_pv}
        (1-forced_outage_rate[t]) * cap_factor[z, t, s, o, h] * InstallGen[z, t, s, o, v])
  <= sum {(z, v, h) in LOCAL_TD_HOURS} InstallLocalTD[z, v];

# interruptible load cannot exceed the target percentage
# (this is conveniently stored in MW terms at the end of the list of cost curve breakpoints)
subject to Maximum_InterruptibleLoad {z in LOAD_ZONES, p in PERIODS}:
  AcceptInterruptibleLoad[z, p] <= interruptible_load_breakpoint_mw[z, p, last(INTERRUPTIBLE_LOAD_BREAKPOINTS)];

# the expenditure on interruptible load must exceed all the linear segments of the supply curve
# (it would be better to use a direct piecewise linear formulation, but that seems to be broken in ampl v. 20070903) 
subject to Piecewise_InterruptibleLoadCost {z in LOAD_ZONES, p in PERIODS, bp in INTERRUPTIBLE_LOAD_BREAKPOINTS}:
  InterruptibleLoadCost[z, p] >= 
    if ord(bp)=1 then 
      AcceptInterruptibleLoad[z, p] * interruptible_load_cost_slope[z, p, bp] 
    else 
      interruptible_load_total_cost[z, p, prev(bp)] 
      + (AcceptInterruptibleLoad[z, p] - interruptible_load_breakpoint_mw[z, p, prev(bp)]) * interruptible_load_cost_slope[z, p, bp] 
    ;

# system load must fall within the allowed range of the base-case load
# (upper and lower limits correspond to the first and last breakpoints of the demand curve)
subject to Minimum_Maximum_Annual_Demand {z in LOAD_ZONES, p in PERIODS}:
  annual_demand_quantity_mwh[z, p, first(ANNUAL_DEMAND_BREAKPOINTS)]
  <= ClearAnnualDemand[z, p] 
  <= annual_demand_quantity_mwh[z, p, last(ANNUAL_DEMAND_BREAKPOINTS)];

# the benefit of satisfying demand must be below all the linear segments of the supply curve
# (it would be better to use a direct piecewise linear formulation, but that is broken in ampl v. 20070903) 
# we could ignore the last segment, because the load can never exceed the last breakpoint,
# but that would make AnnualDemandBenefit unbounded when there is only one breakpoint in the demand curve
subject to Piecewise_AnnualDemandBenefit {z in LOAD_ZONES, p in PERIODS, bp in ANNUAL_DEMAND_BREAKPOINTS}:
  AnnualDemandBenefit[z, p] <= 
    annual_demand_benefit_total[z, p, bp] 
    + (ClearAnnualDemand[z, p] - annual_demand_quantity_mwh[z, p, bp]) * annual_demand_benefit_slope[z, p, bp];
