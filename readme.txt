Switch v. 1.0
June 19, 2012

COPYRIGHT AND LICENSE

Switch is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License version 3 as published by the Free Software Foundation. Modified versions of Switch must include this notice and the AUTHOR ATTRIBUTION / CITATION notice below.

Switch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with Switch.  If not, see <http://www.gnu.org/licenses/>.

AUTHOR ATTRIBUTION / CITATION

In publications based on analysis conducted with Switch, please cite Matthias Fripp (2012), "Switch: A Planning Tool for Power Systems with Large Shares of Intermittent Renewable Energy", Environmental Science & Technology 46 (11), pp 6371–6378, http://dx.doi.org/10.1021/es204645c

In presentations based on analysis conducted with Switch, please cite the Switch project's website at http://www.switch-model.org

SWITCH DESCRIPTION

Switch is a planning model for power systems with large shares of renewable energy. It was written by Matthias Fripp while he was a Ph.D. student at the University of California, Berkeley, a post-doctoral researcher at the University of Oxford, and an assistant professor at the University of Hawaii at Manoa.

A full description of the model is available in Matthias Fripp (2012), "Switch: A Planning Tool for Power Systems with Large Shares of Intermittent Renewable Energy", Environmental Science & Technology 46 (11), pp 6371–6378, http://dx.doi.org/10.1021/es204645c. (Pay special attention to the Supplemental Information provided there and at http://pubs.acs.org/doi/suppl/10.1021/es204645c/suppl_file/es204645c_si_001.pdf.)

Very briefly, Switch is a linear optimization model which chooses how much renewable and conventional generation capacity and transmission capacity to install in the study area over a multi-year period. It makes several decisions: At the start of each "investment period" (e.g., every 4 years) it decides how much capacity to add at each potential wind, solar or natural gas project site and how much transfer capacity to add between different load zones. For each of several hundred study hours (sampled dates), the model chooses how much power to produce from each dispatchable power plant and how much power to send between each pair of load zones. Once built, each wind or solar project automatically produces a specific amount of power, which varies each hour. This amount is proportional to the size of the project (e.g., if the model builds 100 MW of solar at one site, the subsequent output from that project is somewhere between 0-100 MW). Each power plant delivers power to a specific load zone.

This is all governed by a few main constraints: For each hour, the output from power plants within each zone (renewable or conventional) plus imports from other zones minus exports to other zones must equal or exceed the load expected for that zone. Hydroelectric plants must also respect minimum, maximum and monthly-average flow constraints. Additional constraints create a planning reserve margin -- those are described in detail in the paper.

The model makes decisions that will minimize the total cost of power while respecting these constraints. The total cost is made up of capital costs for projects (which are amortized over all the hours when the project could run) and fuel costs, as well as an adder for each ton of CO2 emitted. Future costs are discounted to the first year of the study, and the model doesn't consider capital, fuel or carbon costs that occur after the end of the study.

SWITCH SETUP

You will need copies of AMPL and CPLEX software (or other fast solver for linear programs) in order to run Switch. Unfortunately, this means you'll have to do some advance work to get going.

AMPL may be easiest to get from the AMPL company at http://www.ampl.com . It costs several hundred dollars even for academic use, but you can get a free 30-day trial to get you started.

CPLEX is made by IBM and can be obtained for free under their academic initiative. However, if you get CPLEX direct from IBM, you'll need to do a little extra work to compile an AMPL-compatible version of the CPLEX solver. An alternative would be to get CPLEX from the AMPL company as well. AMPL can sell you a version of CPLEX ready to work with AMPL right away, and they may be able to provide this to you for free if you have signed up for IBM's academic initiative.

Once you have AMPL and CPLEX running, you can run Switch by going to the "data" directory, starting your copy of ampl and typing the commands "include load.run;" and then "include go.run;". You may need to make some minor changes to the configuration if you're running on Windows (later versions will do this automatically; the model is usually run on Mac or Linux computers). 

The model's assumptions can be varied by adjusting parameters either while running ampl or by editing switch.dat or replacing the power system data files with ones of your own. Code for sensitivity studies and post-optimization assessment will be available shortly.

ASSISTANCE

Please contact mfripp@users.sourceforge.net with questions about setting up or using Switch.