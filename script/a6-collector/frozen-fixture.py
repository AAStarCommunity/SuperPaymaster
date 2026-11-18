"""Generate the offline adapter fixture with the real planner and its fake chain."""
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'rq3op'))
from test_three_arm import ThreeArm
fixture = ThreeArm()
fixture.setUp()
print(json.dumps(fixture.build(), sort_keys=True, separators=(',', ':')))
