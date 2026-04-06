# Create/populate the Registrar lookup contract (AddressLookupProto)
# with chain ID → registrar address mappings from chainlink-automation.yaml.
# Requires: $chain (RPC URL) and $tx_key (private key) env vars.
tuples=$(yq 'to_entries | sort_by(.key) | [.[] | "(" + (.key | tostring) + "," + .value.registrarAddress + ")"] | "[" + join(",") + "]"' io/chainlink-automation.yaml)
cast send -r $chain --private-key $tx_key 0x6adD49A791fF1dDDcd91f0AFCB70Cd91c81821ca "make((uint256,address)[])" "$tuples"
