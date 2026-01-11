
############################################################
# Temporary Measures Restoration – Organized Model
# Structure: Sets → Parameters → Variables → Objective → Constraints
############################################################


# ==========================================================
# 1) SETS & INDICES
# ==========================================================
set Lines;                     # all physical lines (including switches & regulators)
set Switches;                  # subset of Lines that are switches
set SW_off;                    # (kept for compatibility; not used)
set Regulators;                # subset of Lines that are voltage regulators
set Buses;                     # bus indices
set Lines_nonReg = Lines diff Regulators;
set Phases;                    # {A,B,C}
set CapB = {83,88,90,92};      # capacitor-bank buses (kept; zeroed in Q-KCL)
set LineConf = {1..13};        # line configuration types (13th for switches)
set Line_3;                    # dimension names for Line param: Length, From, To

# Time sets: Day-1 (full AC-like physics) and Day-2 (active-power only)
set TBuild := {1..24};         # Day-1: full physics (U,Q,PL/QL,KVL, radiality)
set TRun   := {25..48};        # Day-2: P-only KCL (no U/Q/KVL)
set Time   := TBuild union TRun;

# Duration parameters
param DaysBeyond integer >= 0 default 6;  # additional days approximated by Day-2 pattern
param DeltaT >= 0 default 1;              # hours per step (1=h)

# Disaster & temporary measures
set Damaged_Lines_Rep;         # damaged lines that can be repaired
set Damaged_Lines_Unrep;       # damaged lines out of service (not repairable)
set Candidate_Subs;            # candidate portable substation buses
set Candidate_Gen;             # candidate portable generator buses
set Candidate_Lines;           # candidate temporary lines to build

# (Optional) repair-time placeholder
param RT {Damaged_Lines_Rep} default 3;


# ==========================================================
# 2) PARAMETERS (data, costs, limits, routing, fuel)
# ==========================================================

## 2.1 Network & load data
param Line {Lines,Line_3};                 # Length, From, To for each line
param ph {Lines,Phases};                   # phase presence of each line
param PF {Buses,Phases};                   # base active load (kW)
param QF {Buses,Phases};                   # base reactive load (kvar)
param R  {Phases,Phases,LineConf};         # resistance coupling matrix by config
param X  {Phases,Phases,LineConf};         # reactance  coupling matrix by config
param Conf {Lines};                        # config id per line
param Qc {i in CapB, p in Phases};         # capacitor kvar (not used, set to 0 in KCL-Q)

# 24‑hour shape for Day‑1; Day‑2 mirrors Day‑1 profile
param Load_Shape {t in TBuild};
param BuildH integer := card(TBuild);
param Load_Shape_Ext {t in Time} :=
    if t in TBuild then Load_Shape[t] else Load_Shape[t - BuildH];

param U_phase {i in Buses, p in Phases};   # 0/1 phase availability at bus
param V_base := 2.40178;                   # (kV) base phase-to-neutral

# Derived loads (kW/kvar)
param Pd {i in Buses, p in Phases, t in Time}   >= 0 :=
    PF[i,p] * Load_Shape_Ext[t] * U_phase[i,p];

param Qd {i in Buses, p in Phases, t in TBuild} >= 0 :=
    QF[i,p] * Load_Shape_Ext[t] * U_phase[i,p];

## 2.2 Cost parameters (defaults)
param CSubOp >= 0 := 0.08;          # $/kWh portable substation energy
param CGenOp >= 0 := 0.40;          # $/kWh diesel generator all-in variable cost

param SubInstallDefault >= 0 := 100000;                        # $/sub
param cSubInstall {Candidate_Subs} >= 0 := SubInstallDefault;

param GenInstallDefault >= 0 := 50000;                         # $/gen
param cGenInstall {Candidate_Gen}  >= 0 := GenInstallDefault;

# Line costs
param Len_to_miles   >= 0 := 1.0;    # conversion factor if needed
param UnitCostRepair >= 0 := 150000; # $/mile
param UnitCostBuild  >= 0 := 200000; # $/mile
param FixCostRepair  >= 0 := 10000;  # $ per repair job
param FixCostBuild   >= 0 := 15000;  # $ per build job

param cLineRepair {k in Damaged_Lines_Rep} >= 0 :=
    FixCostRepair + UnitCostRepair * ( Line[k,"Length"] * Len_to_miles );

param cLineBuild  {k in Candidate_Lines}   >= 0 :=
    FixCostBuild  + UnitCostBuild  * ( Line[k,"Length"] * Len_to_miles );

# VoLL
param VOLL_default >= 0 := 30;       # $/kWh 15
param cShed {Buses} >= 0 := VOLL_default;

## 2.3 Allocation caps
param Sbar integer >= 0 default 2;   # max portable substations
param Gbar integer >= 0 default 4;   # max portable generators
param Lbar integer >= 0 default 6;   # max candidate lines to build

## 2.4 Power limits & gating parameters
# Install (availability) times
param Ts {i in Candidate_Subs} integer >= 1 default 4;
param Tg {i in Candidate_Gen}  integer >= 1 default 3;

# Ratings
param PpsMax {i in Candidate_Subs} >= 0 default 3000;  # kW/phase
param QpsMax {i in Candidate_Subs} >= 0 default 3000;  # kvar/phase
param PgMax  {i in Candidate_Gen}  >= 0 default 500;   # kW/phase
param QgMax  {i in Candidate_Gen}  >= 0 default 240;   # kvar/phase

# Substation transformer limits
param PTransMax {p in Phases} >= 0 default 10000;
param QTransMax {p in Phases} >= 0 default 10000;

# Line flow limits
param PLineMax {k in Lines} default 6000;
param QLineMax {k in Lines} default 6000;

# Big‑M for KVL gating (kV^2 units)
param Mvolt >= 0 default 50;

## 2.5 Routing parameters
set Crews default {1..4};                       # crew indices
set Depot := {'DEPOT'};                          # depot node label
set Tasks = Damaged_Lines_Rep union Candidate_Lines;
set Nodes = Tasks union Depot;

param tr    {i in Nodes, j in Nodes} >= 0 default 0;  # travel time (h)
param Ttask {k in Tasks}            >= 0 default 0;   # service time (h)
param M_time >= 0 default 1e6;                         # big‑M for routing time

## 2.6 Fuel parameters (diesel)
param FuelRate          >= 0 := 0.07;   # gal/kWh
param GenLF             >= 0 <= 1 := 0.80;
param FuelReserveFactor >= 1      := 1.10;
param MinHours >= 0 := 8;  # desired minimum hours on site
param gmin {i in Candidate_Gen} :=
    FuelReserveFactor * GenLF * (3 * PgMax[i]) * MinHours * FuelRate;

# Total hours used to size gmax and budget (Day‑1 + DaysBeyond×Day‑2)
param Htotal := DeltaT * ( card(TBuild) + DaysBeyond * card(TRun) );

param gmax {i in Candidate_Gen} >= 0 :=
    FuelReserveFactor * GenLF * (3 * PgMax[i]) * Htotal * FuelRate;

param AvgPgMax >= 0 :=
    (if card(Candidate_Gen) > 0
     then (sum {i in Candidate_Gen} PgMax[i]) / card(Candidate_Gen)
     else 0);

param FuelBudget >= 0 :=
    FuelReserveFactor * GenLF * Htotal * FuelRate * (3 * AvgPgMax) * Gbar;


# ==========================================================
# 3) VARIABLES
# ==========================================================

## 3.1 Topology (line status)
var uL {k in Lines, t in Time} binary;

## 3.2 Source injections (substation, portable subs/gens)
var PTrans {p in Phases, t in Time}    >= 0;          # kW (Day‑1 & Day‑2)
var QTrans {p in Phases, t in TBuild}  >= 0;          # kvar (Day‑1 only)

var Pps {i in Candidate_Subs, p in Phases, t in Time}   >= 0;  # kW
var Pg  {i in Candidate_Gen,  p in Phases, t in Time}   >= 0;  # kW
var Qps {i in Candidate_Subs, p in Phases, t in TBuild} >= 0;  # kvar (Day‑1)
var Qg  {i in Candidate_Gen,  p in Phases, t in TBuild} >= 0;  # kvar (Day‑1)

## 3.3 Power flows & voltages
var PL {k in Lines, p in Phases, t in Time}   >= -4000, <= 4000;  # kW
var QL {k in Lines, p in Phases, t in TBuild} >= -4000, <= 4000;  # kvar (Day‑1)
var U  {i in Buses, p in Phases, t in TBuild};                     # kV^2 (Day‑1)

## 3.4 Install / build decisions
var xSub   {i in Candidate_Subs} binary;
var xGen   {i in Candidate_Gen}  binary;
var xRep   {k in Damaged_Lines_Rep} binary;
var xBuild {k in Candidate_Lines}   binary;

## 3.5 Load service indicator
var y {i in Buses, t in Time} binary;

## 3.6 Routing variables
var xArc   {i in Nodes, j in Nodes, c in Crews} binary;  # crew moves i→j
var alpha  {k in Nodes, c in Crews} >= 0;                # arrival time at node
var zAvail {k in Tasks, t in TBuild} binary;             # availability time pick

## 3.7 Radiality & virtual flow (Day‑1 only)
set VRoot := {0};
set AllNodes := Buses union VRoot;

var Beta  {i in AllNodes, j in Buses, t in TBuild} binary;  # parent i→child j
var flow  {k in Lines, t in TBuild};                        # virtual flow on lines
var Sflow {i in Buses, t in TBuild} >= 0;                   # source flow from 0
param NBUS integer >= 1 default 10*card(Buses);

## 3.8 Fuel allocation
var FuelAlloc {i in Candidate_Gen} >= 0;


# ==========================================================
# 4) OBJECTIVE
# ==========================================================
# Install + line actions + Day‑1 energy + DaysBeyond × Day‑2 energy + VoLL
minimize Zetta:
      sum {i in Candidate_Subs} cSubInstall[i] * xSub[i]
    + sum {i in Candidate_Gen}  cGenInstall[i]  * xGen[i]
    + sum {k in Damaged_Lines_Rep} cLineRepair[k] * xRep[k]
    + sum {k in Candidate_Lines}   cLineBuild[k]  * xBuild[k]

    + DeltaT * (
          sum {i in Candidate_Subs, p in Phases, t in TBuild} CSubOp * Pps[i,p,t]
        + sum {i in Candidate_Gen,  p in Phases, t in TBuild} CGenOp * Pg[i,p,t]
        + DaysBeyond * (
              sum {i in Candidate_Subs, p in Phases, t in TRun} CSubOp * Pps[i,p,t]
            + sum {i in Candidate_Gen,  p in Phases, t in TRun} CGenOp * Pg[i,p,t]
          )
      )
      + DeltaT * (
          sum {p in Phases, t in TBuild} CSubOp * PTrans[p,t]
        + DaysBeyond * sum {p in Phases, t in TRun} CSubOp * PTrans[p,t]
  )
    + DeltaT * (
      sum {i in Buses, t in TBuild}  cShed[i] * sum {p in Phases} (1 - y[i,t]) * Pd[i,p,t]
    + DaysBeyond * sum {i in Buses, t in TRun} cShed[i] * sum {p in Phases} (1 - y[i,t]) * Pd[i,p,t]
  )
;


# ==========================================================
# 5) CONSTRAINTS
# ==========================================================

# Allocation constraints
s.t. MaxPortableSubs: sum {i in Candidate_Subs} xSub[i] <= Sbar;
s.t. MaxPortableGen:  sum {i in Candidate_Gen}  xGen[i] <= Gbar;
s.t. MaxBuiltLines:   sum {k in Candidate_Lines} xBuild[k] <= Lbar;

## 5.1 Routing (crew tours & timing)
s.t. StartFromDepot {c in Crews}:
    sum {j in Tasks} xArc['DEPOT', j, c] <= 1;

s.t. ReturnToDepot {c in Crews}:
    sum {i in Tasks} xArc[i, 'DEPOT', c] <= 1;

s.t. NoSelfArcs {c in Crews, i in Nodes}:
    xArc[i, i, c] = 0;

# Flow conservation at each task for each crew
s.t. FlowBalance {c in Crews, l in Tasks}:
    sum {k in Nodes : k <> l} xArc[k, l, c]
  - sum {k in Nodes : k <> l} xArc[l, k, c] = 0;

# Visit a task iff it is chosen (repair/build)
s.t. VisitIfRepair {l in Damaged_Lines_Rep}:
    sum {c in Crews, k in Nodes} xArc[k, l, c] = xRep[l];

s.t. VisitIfBuild {l in Candidate_Lines}:
    sum {c in Crews, k in Nodes} xArc[k, l, c] = xBuild[l];

# Time propagation (MTZ‑style)
s.t. DepotAlpha {c in Crews}: alpha['DEPOT', c] = 0;

s.t. ArrivalTime {c in Crews, i in Nodes, l in Tasks}:
    alpha[i, c]
  + (if i in Tasks then Ttask[i] else 0)
  + tr[i, l]
  - (1 - xArc[i, l, c]) * M_time
  <= alpha[l, c];

s.t. AlphaZeroUnlessVisited {c in Crews, l in Tasks}:
    alpha[l, c] <= M_time * sum {i in Nodes} xArc[i, l, c];

# Availability picks and line status accumulation (Day‑1)
s.t. AvailPickRepair {k in Damaged_Lines_Rep}:
    sum {t in TBuild} zAvail[k, t] = xRep[k];

s.t. AvailPickBuild  {k in Candidate_Lines}:
    sum {t in TBuild} zAvail[k, t] = xBuild[k];

s.t. AvailabilityTiming {k in Tasks}:
    sum {t in TBuild} t * zAvail[k, t]
    >= sum {c in Crews} ( alpha[k, c] + Ttask[k] * sum {j in Nodes} xArc[k, j, c] );

s.t. LineStatusFromAvail {k in Tasks, t in TBuild}:
    uL[k, t] = sum {tau in TBuild : tau <= t} zAvail[k, tau];

# All loads served from t >= 24 (end of Day‑1 and throughout Day‑2)
# s.t. all_loads_served_end {i in Buses, t in Time : t >= 24}:
#    y[i,t] = 1;

# Freeze topology (Day‑2 = topology at end of Day‑1)
s.t. HoldTopology {k in Lines, t in TRun}:
    uL[k,t] = uL[k,24];


## 5.2 Power limits & gating

# Portable substation active power
s.t. Pps_Upper_On    {i in Candidate_Subs, p in Phases, t in Time : t >= Ts[i]}:
    Pps[i,p,t] <= xSub[i] * PpsMax[i];
s.t. Pps_Zero_Before {i in Candidate_Subs, p in Phases, t in Time : t <  Ts[i]}:
    Pps[i,p,t] = 0;

# Portable generator active power
s.t. Pg_Upper_On     {i in Candidate_Gen, p in Phases, t in Time : t >= Tg[i]}:
    Pg[i,p,t] <= xGen[i] * PgMax[i];
s.t. Pg_Zero_Before  {i in Candidate_Gen, p in Phases, t in Time : t <  Tg[i]}:
    Pg[i,p,t] = 0;

# Reactive power (Day‑1 only)
s.t. Qps_Upper_On    {i in Candidate_Subs, p in Phases, t in TBuild : t >= Ts[i]}:
    Qps[i,p,t] <= xSub[i] * QpsMax[i];
s.t. Qps_Zero_Before {i in Candidate_Subs, p in Phases, t in TBuild : t <  Ts[i]}:
    Qps[i,p,t] = 0;

s.t. Qg_Upper_On     {i in Candidate_Gen, p in Phases, t in TBuild : t >= Tg[i]}:
    Qg[i,p,t] <= xGen[i] * QgMax[i];
s.t. Qg_Zero_Before  {i in Candidate_Gen, p in Phases, t in TBuild : t <  Tg[i]}:
    Qg[i,p,t] = 0;

# Substation limits
s.t. Sub_P_Limits {p in Phases, t in Time}:
    0 <= PTrans[p,t] <= PTransMax[p];
s.t. Sub_Q_Limits {p in Phases, t in TBuild}:
    0 <= QTrans[p,t] <= QTransMax[p];

# Line flow limits (active both days; reactive Day‑1)
s.t. Line_P_UB {k in Lines, p in Phases, t in Time}:
    PL[k,p,t] <=  uL[k,t] * ph[k,p] * PLineMax[k];
s.t. Line_P_LB {k in Lines, p in Phases, t in Time}:
    PL[k,p,t] >= -uL[k,t] * ph[k,p] * PLineMax[k];

s.t. Line_Q_UB {k in Lines, p in Phases, t in TBuild}:
    QL[k,p,t] <=  uL[k,t] * ph[k,p] * QLineMax[k];
s.t. Line_Q_LB {k in Lines, p in Phases, t in TBuild}:
    QL[k,p,t] >= -uL[k,t] * ph[k,p] * QLineMax[k];


## 5.3 Fuel logistics

# Install‑dependent bounds & total budget
s.t. Fuel_Alloc_Bounds_LB {i in Candidate_Gen}:
    FuelAlloc[i] >= xGen[i] * gmin[i];
s.t. Fuel_Alloc_Bounds_UB {i in Candidate_Gen}:
    FuelAlloc[i] <= xGen[i] * gmax[i];
s.t. Fuel_Budget_Cap:
    sum {i in Candidate_Gen} FuelAlloc[i] <= FuelBudget;

# Consumption: Day‑1 + DaysBeyond × Day‑2
s.t. Fuel_Consumption {i in Candidate_Gen}:
    DeltaT * (
          sum {p in Phases, t in TBuild} Pg[i,p,t] * FuelRate
        + DaysBeyond * sum {p in Phases, t in TRun} Pg[i,p,t] * FuelRate
    ) <= FuelAlloc[i];


## 5.4 Power flow (Day‑1 physics); Day‑2 uses P‑only balance via KCL_P_Build

# Slack (substation) voltage (Day‑1)
subject to USub {p in Phases, t in TBuild}:
    U[150,p,t] = 1.00 * V_base^2;

# Nodal active power balance (Day‑1 and Day‑2)
subject to KCL_P_Build {i in Buses, p in Phases, t in Time}:
      sum {dummy in 1..1 : i = 150} PTrans[p,t]
    + sum {k in Lines : Line[k,"To"]   = i} PL[k,p,t]
    - sum {k in Lines : Line[k,"From"] = i} PL[k,p,t]
    + sum {j in Candidate_Subs : j = i} Pps[j,p,t]
    + sum {j in Candidate_Gen  : j = i} Pg[j,p,t]
    - y[i,t] * Pd[i,p,t] = 0;

# Nodal reactive power balance (Day‑1 only; capacitors zeroed)
subject to KCL_Q_Build {i in Buses, p in Phases, t in TBuild}:
      sum {dummy in 1..1 : i = 150} QTrans[p,t]
    + sum {k in Lines : Line[k,"To"]   = i} QL[k,p,t]
    - sum {k in Lines : Line[k,"From"] = i} QL[k,p,t]
    + sum {j in CapB : j = i} Qc[j,p]*0
    + sum {j in Candidate_Subs : j = i} Qps[j,p,t]
    + sum {j in Candidate_Gen  : j = i} Qg[j,p,t]
    - y[i,t] * Qd[i,p,t] = 0;

# Linearized KVL (Day‑1 only) with gating
subject to Voltage_between_nodes1 {i in Lines_nonReg, p in Phases, t in TBuild}:
    U[Line[i,"From"], p, t] - U[Line[i,"To"], p, t]
    <= 2 * Line[i,"Length"] * (
         PL[i,"A",t]*R[p,"A",Conf[i]] + PL[i,"B",t]*R[p,"B",Conf[i]] + PL[i,"C",t]*R[p,"C",Conf[i]]
       + QL[i,"A",t]*X[p,"A",Conf[i]] + QL[i,"B",t]*X[p,"B",Conf[i]] + QL[i,"C",t]*X[p,"C",Conf[i]]
       ) / 1000
     + Mvolt * (2 - uL[i,t] - ph[i,p]);

subject to Voltage_between_nodes2 {i in Lines_nonReg, p in Phases, t in TBuild}:
    U[Line[i,"From"], p, t] - U[Line[i,"To"], p, t]
    >= 2 * Line[i,"Length"] * (
         PL[i,"A",t]*R[p,"A",Conf[i]] + PL[i,"B",t]*R[p,"B",Conf[i]] + PL[i,"C",t]*R[p,"C",Conf[i]]
       + QL[i,"A",t]*X[p,"A",Conf[i]] + QL[i,"B",t]*X[p,"B",Conf[i]] + QL[i,"C",t]*X[p,"C",Conf[i]]
       ) / 1000
     - Mvolt * (2 - uL[i,t] - ph[i,p]);

# Voltage magnitude bounds (Day‑1)
subject to voltage_min {i in Buses, p in Phases, t in TBuild}:
    U[i,p,t] >= (V_base * 0.90)^2 * U_phase[i,p];
subject to voltage_max {i in Buses, p in Phases, t in TBuild}:
    U[i,p,t] <= (V_base * 1.10)^2 * U_phase[i,p];

# Regulators (Day‑1)
subject to voltageReg1 {i in Regulators, p in Phases, t in TBuild : ph[i,p] <> 0}:
    U[Line[i,"From"], p, t] * 0.81 <= U[Line[i,"To"], p, t];
subject to voltageReg2 {i in Regulators, p in Phases, t in TBuild : ph[i,p] <> 0}:
    U[Line[i,"From"], p, t] * 1.21 >= U[Line[i,"To"], p, t];


## 5.5 Radiality + virtual flow (Day‑1 only)

# Exactly one directed parent on an energized line
s.t. vf_1 {k in Lines, t in TBuild}:
    Beta[ Line[k,"From"], Line[k,"To"], t ]
  + Beta[ Line[k,"To"],   Line[k,"From"], t ] = uL[k,t];

# Each bus has at most one parent (can be a root if attached to virtual source 0)
s.t. vf_2 {j in Buses, t in TBuild}:
    sum {i in AllNodes} Beta[i,j,t] <= 1;

# Source and line virtual-flow bounds
s.t. vf_4 {i in Buses, t in TBuild}:
    Sflow[i,t] <= NBUS * Beta[0,i,t];

s.t. vf_5 {i in Lines, t in TBuild}:
    flow[i,t] <=  NBUS * uL[i,t];
s.t. vf_6 {i in Lines, t in TBuild}:
    flow[i,t] >= -NBUS * uL[i,t];

# Virtual-flow balance with unit demand at every bus
s.t. vf_7 {i in Buses, t in TBuild}:
    Sflow[i,t]
  + sum {j in Lines : Line[j,"To"]   = i} flow[j,t]
  = 1
  + sum {j in Lines : Line[j,"From"] = i} flow[j,t];

# Roots: fixed substation, candidate subs/gens become roots if installed
s.t. root_fixed_subs {t in TBuild}:
    Beta[0, 150, t] = 1;
s.t. root_cand_subs  {i in Candidate_Subs, t in TBuild}:
    Beta[0, i, t] >= xSub[i];
s.t. root_cand_gens  {i in Candidate_Gen,  t in TBuild}:
    Beta[0, i, t] >= xGen[i];


## 5.6 Base line statuses (Day‑1) & required tie

set Lines_FixedOn :=
    Lines diff (Damaged_Lines_Rep union Damaged_Lines_Unrep union Candidate_Lines union Switches);

s.t. BaseLinesOn    {k in Lines_FixedOn,   t in TBuild}: uL[k,t] = 1;
s.t. UnrepairableOff{k in Damaged_Lines_Unrep, t in TBuild}: uL[k,t] = 0;
s.t. Main_Sub_On    {t in TBuild}: uL['150_149', t] = 1;

# ---- End of model ----
