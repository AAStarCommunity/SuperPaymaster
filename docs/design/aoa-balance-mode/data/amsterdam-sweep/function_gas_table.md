tests passing under both: 213
| function (implementation frame) | samples | Prague min / median / max | Amsterdam min / median / max | ratio of medians | paired ratio min..max |
|---|---|---|---|---|---|
| `SuperPaymaster::postOp` | 23 | 1,479 / 105,823 / 156,172 | 1,479 / 70,274 / 691,692 | 0.66x | 0.63x..4.72x |
| `SuperPaymaster::validatePaymasterUserOp` | 6 | 184,628 / 188,773 / 188,773 | 800,668 / 804,813 / 804,813 | 4.26x | 4.26x..4.34x |
| `xPNTsTokenV2::settleCredit` | 5 | 47,650 / 47,650 / 47,650 | 27,850 / 27,850 / 27,850 | 0.58x | 0.58x..0.58x |
| `xPNTsTokenV2::settleLocked` | 28 | 5,973 / 33,580 / 41,180 | 5,973 / 23,680 / 45,680 | 0.71x | 0.69x..1.11x |
| `xPNTsTokenV2::tryLockForGas` | 61 | 2,372 / 76,002 / 162,281 | 2,372 / 340,062 / 690,401 | 4.47x | 1.00x..4.80x |
| `xPNTsTokenV2::tryReserveCredit` | 15 | 2,187 / 13,507 / 111,578 | 2,187 / 13,507 / 358,333 | 1.00x | 1.00x..3.82x |
