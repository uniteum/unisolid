# Create/populate the Uniswap V2 Router lookup contract (AddressLookupProto)
# with chain ID → router address mappings from UniswapV2Router.json.
# Requires: $chain (RPC URL) and $tx_key (private key) env vars.
tuples=$(jq -r '[.[] | "(\(.key),\(.value))"] | join(",")' io/prod/UniswapV2Router.json)
cast send -r $chain --private-key $tx_key 0x6adD49A791fF1dDDcd91f0AFCB70Cd91c81821ca "make((uint256,address)[])" "[$tuples]"
