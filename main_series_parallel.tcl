suppress_message UID-101
suppress_message UID-95

set debug false

# A nested dictionary to record each node's information, including reachable DFFs, buffer count 
set node_info_dic [dict create]
# A nested dictionary to record the amount of buffers on a path from the D pin to the Q pin
set tracked_result [dict create]

set config [dict create netlist        "" \
                        top            "" \
                        start_cells    "" \
                        end_cells      "" \
                        DFF_name       "" \
                        D_name         "" \
                        Q_name         "" \
                        buffer_name    "" \
                        threshold      ""]

proc set_node_info_dic { target_cell mode value } {
    global node_info_dic
    set key [get_attribute $target_cell full_name]
    set temp [dict get $node_info_dic $key]
    dict set temp $mode $value
    dict set node_info_dic $key $temp
}

proc get_node_info_dic { target_cell mode } {
    global node_info_dic
    set key [get_attribute $target_cell full_name]
    return [dict get [dict get $node_info_dic $key] $mode]
}

proc check_if_inside {data target_list} {
    set existed false
    foreach_in_collection target $target_list {
        if ![compare_collections $data $target] {
            set existed true
        }
    }
    return $existed
}

proc buffer_check {target_cell} {
    global config
    set buffer_regexp [dict get $config buffer_name]
    # debug_display "************************BUFFER CHECK************************"
    # debug_display $buffer_regexp
    # debug_display [get_attribute $target_cell ref_name]
    # debug_display [string match $buffer_regexp [get_attribute $target_cell ref_name]]
    return [string match $buffer_regexp [get_attribute $target_cell ref_name]]
}

proc sequential_check {target_cell} {
    global config
    set DFF_regexp [dict get $config DFF_name]

    if [string equal $DFF_regexp ""] {
        return [get_attribute $target_cell is_sequential]
    } else {
        if [string match $DFF_regexp [get_attribute $target_cell ref_name]] {
            return true
        } else {
            return false
        }
    }
}

proc valid_DFF_check {target_cell end_cells Q_regexp} {
    set valid false
    set out_pins [get_pins -of_object $target_cell -filter {@pin_direction=="out"}]
    set Q_pin ""
    # assure the cell has valid Q pin
    foreach_in_collection dff_out $out_pins {
        if [string match $Q_regexp [get_attribute $dff_out name]] { 
            set valid true
            set Q_pin $dff_out
            break
        }
    }
    # assure the cell is a sub module(cell) of the specified end cell
    set father_cell [lindex [split [get_attribute $target_cell full_name] /] end-1]
    if { ![check_if_inside [get_cells $father_cell] $end_cells]} {
        set valid false
    }
    return "$valid [get_attribute $Q_pin full_name]"
}

# This function aims to extract all DFF's D pins from the user-specified module
proc get_DFF_pins {cur_cell} {
    # get all DFF by comparing cell's name with regular expression or using "-filter @is_sequential"
    global config
    set DFF_regexp [dict get $config DFF_name]
    set D_regexp [dict get $config D_name]
    # echo "********Start to find D pins********"
    set regexp "*[get_attribute $cur_cell full_name]*"
    if {$DFF_regexp == ""} { 
        # echo "Find way: check if @is_sequential is true"
        set dff_in_cell [filter [get_cells -filter @is_sequential -hierarchical] "@full_name=~$regexp"]
    } else {
        # echo "Find way: compared by regular expression"
        set dff_in_cell [filter [get_references $DFF_regexp -hierarchical] "@full_name=~$regexp"]
    }
    # filter out all D pins in these DFFs
    set d_pins {}
    foreach_in_collection cur_dff $dff_in_cell {
        append_to_collection d_pins [get_pins -of_object $cur_dff -filter "@name=~$D_regexp"]
    }
    # echo "********Finish D-pin finding********"
    return $d_pins
}

proc dfs_path_tracking {d_pin} {
    global node_info_dic
    global config

    set Q_regexp [dict get $config Q_name]
    set end_cells [dict get $config end_cells]
    set dff [get_cells -of_object $d_pin]

    set start_cells [remove_from_collection [all_fanin -to $d_pin -flat -level 1 -only_cells] $dff]
    foreach_in_collection start $start_cells {
        if {[sequential_check $start]} {
            # append terminal node(DFF) into dictionary
            dict append node_info_dic [get_attribute $start full_name] [dict create reachable_dff "" conti_buf 0]

            # check if the DFF is valid
            set dff_result [valid_DFF_check $start $end_cells $Q_regexp]
            set valid [lindex $dff_result 0]
            set Q_pin [lindex $dff_result 1]
            if $valid {
                dict append tracked_result $Q_pin "0 0"
                set_node_info_dic $start reachable_dff $Q_pin
            }
        } else {
            dfs_visit $start $end_cells $Q_regexp
        }
    }
}

proc dfs_visit {cell_to_visit end_cells Q_regexp} {
    global node_info_dic
    global tracked_result

    # query_objects $cell_to_visit

    set pins_to_depart [get_pins -of_object $cell_to_visit -filter {@pin_direction=="in"}]
    set all_fanin_cells {}

    foreach_in_collection pin $pins_to_depart {
        set fanin_cells [remove_from_collection [all_fanin -to $pin -flat -level 1 -only_cells] $cell_to_visit]

        foreach_in_collection next_visit_cell $fanin_cells {
            append_to_collection all_fanin_cells $next_visit_cell -unique

            if {![dict exists $node_info_dic [get_attribute $next_visit_cell full_name]]} {
                if {[sequential_check $next_visit_cell]} {
                    # append terminal node(DFF) into dictionary
                    dict append node_info_dic [get_attribute $next_visit_cell full_name] [dict create reachable_dff "" conti_buf 0]

                    # check if the DFF is valid
                    set dff_result [valid_DFF_check $next_visit_cell $end_cells $Q_regexp]
                    set valid [lindex $dff_result 0]
                    set Q_pin [lindex $dff_result 1]
                    if $valid {
                        # set end_cell_name [get_attribute $next_visit_cell full_name]
                        # debug_display "End -- $end_cell_name"
                        dict append tracked_result $Q_pin "0 0"
                        set_node_info_dic $next_visit_cell reachable_dff $Q_pin
                    }
                    
                } else {
                    dfs_visit $next_visit_cell $end_cells $Q_regexp
                }
            }
        }
    }

    # append current cell into dictionary "node_info_dic"
    if { ![dict exists $node_info_dic [get_attribute $cell_to_visit full_name]] } {
        dict append node_info_dic [get_attribute $cell_to_visit full_name] [dict create reachable_dff "" conti_buf 0]
    } else {
        echo "ERROR!! Visit a cell more than once"
        exit 1
    }
    # debug_display -n "all fanin: "
    # query_objects $all_fanin_cells

    # find all reachable DFFs' Q pins 
    set union {}
    set max_buffer 0
    foreach_in_collection adj_cell $all_fanin_cells {
        set reachable_dff_Qpin [get_node_info_dic $adj_cell reachable_dff]
        set conti_buffer [get_node_info_dic $adj_cell conti_buf]
        if {$conti_buffer>$max_buffer} {
            set max_buffer $conti_buffer
        }
        # debug_display "r: $reachable_dffs"
        set union [lsort -unique [list {*}$union {*}$reachable_dff_Qpin]]
        # debug_display "u $union"
    }
    set_node_info_dic $cell_to_visit reachable_dff $union
    # debug_display [llength $union]
    set cell_name [get_attribute $cell_to_visit full_name]
    # debug_display "current cell: $cell_name"
    if [buffer_check $cell_to_visit] {
        # debug_display "BUFFER!!!!!!!!!!!!!!!!!!BUFFER!!!!!!!!!!!!!!!!!!BUFFER!!!!!!!!!!!!!!!!!!"
        set max_buffer [expr $max_buffer+1]
        set_node_info_dic $cell_to_visit conti_buf $max_buffer
        foreach q_pin $union {
            if {$max_buffer < [lindex [dict get $tracked_result $q_pin] 1]} {
                set max_buffer [lindex [dict get $tracked_result $q_pin] 1]
            }
            set buffer_count [lindex [dict get $tracked_result $q_pin] 0]
            set update_buffer_count [expr $buffer_count+1]
            dict set tracked_result $q_pin "$update_buffer_count $max_buffer"
        }
    }
}

proc write_to_output_file {Count_Table {filename "buffer_count.txt"}} {
    global config
    set threshold [dict get $config threshold]

    echo "Write results to output file -- $filename..."
    set all_start [dict keys $Count_Table]
    set result_list ""
    foreach d_pin $all_start {
        set all_end [dict keys [dict get $Count_Table $d_pin]]
        foreach q_pin $all_end {
            if {[lindex [dict get [dict get $Count_Table $d_pin] $q_pin] 0]>=$threshold} {
                set result_list [linsert $result_list end "$d_pin $q_pin [dict get [dict get $Count_Table $d_pin] $q_pin]"]
            }
        }
    }
    debug_display "insert finish"
    set output_file [open $filename "w"]
    puts $output_file [format "%-40s%-40s%10s%20s" "Start D Pin" "End Q Pin" "Buffer Amount" "Continuous Buf."]
    puts $output_file "-------------------------------------------------------------------------------------------------------------------"
    foreach item $result_list {
        puts $output_file [format "%-40s%-40s%10s%20s" [lindex $item 0] [lindex $item 1] [lindex $item 2] [lindex $item 3]]
    }
    close $output_file
}

proc sort_buffer_count {result_list mode} {
    if {}
}

# This progress bar code is copied from https://wiki.tcl-lang.org/page/text+mode+%28terminal%29+progress+bar+%2F+progressbar
proc progress_init {tot} {
   set ::progress_start     [clock seconds]
   set ::progress_last      0
   set ::progress_last_time 0
   set ::progress_tot       $tot
}

proc progress_tick {cur} {
   set now [clock seconds]
   set tot $::progress_tot

   if {$cur > $tot} {
       set cur $tot
   }
   if {($cur >= $tot && $::progress_last < $cur) ||
       ($cur - $::progress_last) >= (0.01 * $tot) ||
       ($now - $::progress_last_time) >= 5} {
       set ::progress_last $cur
       set ::progress_last_time $now
       set percentage [expr round($cur*100/$tot)]
       set ticks [expr $percentage/2]
       if {$cur == 0} {
           set eta   ETA:[format %7s Unknown]
       } elseif {$cur >= $tot} {
           set eta   TOT:[format %7d [expr int($now - $::progress_start)]]s
       } else {
           set eta   ETA:[format %7d [expr int(($tot - $cur) * ($now - $::progress_start)/$cur)]]s
       }
       set lticks [expr 50 - $ticks]
       set str "[format %3d $percentage]%|[string repeat = $ticks]"
       append str "[string repeat . $lticks]|[format %8d $cur]/[format %8d $tot]|$eta\r"
       puts -nonewline stdout $str
       if {$cur >= $tot} {
           puts ""
       }
       flush stdout
   }
}


proc debug_display { content {newline true} } {
    global debug
    if $debug {
        if $newline {
            echo $content
        } else {
            echo -n $content
        }
    }
}

proc main args {
    echo "=================================================="
	echo "        START!! Start to Count Buffer....."
	echo "=================================================="

    parse_proc_arguments -args $args results
    global node_info_dic
    global tracked_result
    global config

    set FINAL_Buffer_Count_Table [dict create]

    # ''''''
    ##declare and initialize parameters##
    #  1. netlist filename,
    #  2. start cells,
    #  3. end cells, 
    #  4. DFF's regular expression, 
    #  5. Buffer's regular expression,
    #  6. threshold for buffer count
    # ''''''

    dict set config top $results(-top)
    dict set config start_cells $results(-start)
    dict set config end_cells $results(-end)
    if {"-f" in [array names results]} { 
        dict set config netlist $results(-f)
        read_verilog $netlist
    } else { dict set config netlist "" }
    if {"-dff" in [array names results]} { dict set config DFF_name $results(-dff)
    } else { dict set config DFF_name "" }
    if {"-Dpin" in [array names results]} { dict set config D_name $results(-Dpin)
    } else { dict set config D_name "*D*" }
    if {"-Qpin" in [array names results]} { dict set config Q_name $results(-Qpin)
    } else { dict set config Q_name "*Q*" }
    if {"-b" in [array names results]} { dict set config buffer_name $results(-b)
    } else { dict set config buffer_name "*BUF*" }
    if {"-t" in [array names results]} { dict set config threshold $results(-t)
    } else { dict set config threshold 0 }

    echo "=======================================Input Information======================================="
    echo [format "search field: {%s}\nstart module: {%s}\nend module: {%s}\nDFF's regular exprssion: {%s}\nBuffer's regular exprssion: {%s}\nthreshold: %s"\
    [get_attribute [dict get $config top] name] [get_attribute [dict get $config start_cells] name] [get_attribute [dict get $config end_cells] name] [dict get $config DFF_name] [dict get $config buffer_name] [dict get $config threshold]]
    echo "==============================================================================================="
    
    current_design [dict get $config top]
    
    set temp {}
    foreach_in_collection cur_cell [dict get $config start_cells] {
        set DPins [get_DFF_pins $cur_cell] 
        if {[sizeof_collection $DPins]!=0} {
            append_to_collection temp $cur_cell
        }
    }
    dict set config start_cells $temp
    foreach_in_collection cur_cell [dict get $config start_cells] {
        query_objects $cur_cell
    }


    set temp {}
    foreach_in_collection cur_cell [dict get $config end_cells] {
        set DPins [get_DFF_pins $cur_cell]
        if {[sizeof_collection $DPins]!=0} {
            append_to_collection temp $cur_cell
        }
    }
    dict set config end_cells $temp

    echo "final"
    query_objects [dict get $config start_cells]
    query_objects [dict get $config end_cells]

    foreach_in_collection cur_cell [dict get $config start_cells] {
        echo [format "Processing cell ==> %s..." [get_attribute $cur_cell name]]
        set DPins [get_DFF_pins $cur_cell]
        set Total_iter [sizeof_collection $DPins]
        set Cur_iter 1

        debug_display "To find [sizeof_collection $DPins] D pins"
        
        # set m 60
        # set n 100
        # set DPins [index_collection $DPins $m $n]
        # set Total_iter [expr $n-$m+1]

        progress_init $Total_iter
        
        foreach_in_collection d_pin $DPins {
            set TIME_start [clock clicks -milliseconds]

            progress_tick $Cur_iter
            incr Cur_iter

            dict append FINAL_Buffer_Count_Table [get_attribute $d_pin full_name] ""
            debug_display "start d pin: [get_attribute $d_pin full_name]"
            dfs_path_tracking $d_pin
            dict set FINAL_Buffer_Count_Table [get_attribute $d_pin full_name] $tracked_result
            debug_display [llength [dict keys $node_info_dic]]
            debug_display [llength [dict keys $tracked_result]]
            set node_info_dic [dict create]
            set tracked_result [dict create]
            debug_display "result:  [dict get $FINAL_Buffer_Count_Table [get_attribute $d_pin full_name]]"

            set end [clock seconds]
            set TIME_taken [expr [clock clicks -milliseconds] - $TIME_start]
            debug_display [format "Cost time :%f" $TIME_taken]
        }
    }

    write_to_output_file $FINAL_Buffer_Count_Table

    echo "Finish all tasks..."
}

define_proc_attributes main \
-info "main function" \
-define_args {
    {-f "netlist filename" "*.v" string {optional}}
    {-top "the topmost design name" "" string {required}}
    {-start "start module list" "" list {required}}
    {-end "end module list" "" list {required}}
    {-dff "DFF's regular expression" "*DFF*" list {optional}}
    {-Dpin "D Pin's regular expression" "*D*" list {optional}}
    {-Qpin "D Pin's regular expression" "*D*" list {optional}}
    {-b "Buffer's regular expression" "*BUF*" list {optional}}
    {-t "threshold for buffer count" "0" int {optional}}
}
