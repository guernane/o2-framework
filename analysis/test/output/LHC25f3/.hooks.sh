AdjustJson () 
{ 
    :
}
Clean () 
{ 
    case "${1:-}" in 
        1)
            :
        ;;
        2)
            rm -f "$OUTPUT_DIR"/dpl-config-*.json 2> /dev/null || true
        ;;
    esac
}
