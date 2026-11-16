import importoccurrence.Planner as P;
import importoccurrence.Planner;
import importoccurrence.Planner as Q;
function main():Int return Planner.fingerprint(P.plan()) + Q.plan() - 40;
