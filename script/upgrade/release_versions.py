"""Release targets follow source; live pins describe the independently authenticated chain."""
RELEASE_VERSIONS = {
    'BLSAggregator': 'BLSAggregator-4.14.2',
    'Registry': 'Registry-5.10.1',
    'SuperPaymaster': 'SuperPaymaster-5.5.3',
    'SuperPaymasterLens': 'SuperPaymasterLens-1.2.4',
}
# Pin-time Sepolia versions track the chain, not the source or upgrade targets.
LIVE_VERSIONS = {
    'Registry': 'Registry-5.8.0',
    'SuperPaymaster': 'SuperPaymaster-5.4.2',
}
