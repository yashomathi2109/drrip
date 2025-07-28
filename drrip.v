module drrip_cache #(
    parameter NUM_WAYS = 16,
    parameter NUM_SETS = 128,
    parameter RRPV_BITS = 2,
    parameter SET_INDEX_WIDTH = $clog2(NUM_SETS),
    parameter PSEL_BITS = 10,
    parameter SDM_SETS = 32  // Number of sets for each SDM as mentioned in paper
)(
    input logic clk,
    input logic rst,
    input logic valid,
    input logic [SET_INDEX_WIDTH-1:0] set_index,
    input logic [3:0] access_way,
    input logic hit,
    input logic miss,

    output logic [3:0] victim_way,
    output logic victim_ready,
    output logic [PSEL_BITS-1:0] psel_counter
);

    // Constants from paper
    localparam RRPV_MAX = (1 << RRPV_BITS) - 1;           // 3 for 2-bit RRPV (distant future)
    localparam RRPV_LONG = RRPV_MAX - 1;                  // 2 for 2-bit RRPV (long re-reference)
    localparam RRPV_NEAR = 0;                             // 0 (near-immediate re-reference)
    localparam PSEL_MAX = (1 << PSEL_BITS) - 1;          // 1023 for 10-bit counter
    localparam PSEL_MID = PSEL_MAX / 2;                   // 511 (threshold)
    localparam BIP_EPSILON = 32;                          // 1/32 probability as mentioned in paper

    // RRPV storage for each cache block
    logic [RRPV_BITS-1:0] rrpv_table [NUM_SETS-1:0][NUM_WAYS-1:0];
    
    // PSEL counter for set dueling
    logic [PSEL_BITS-1:0] psel_reg;
    assign psel_counter = psel_reg;
    
    // BIP counter for bimodal insertion (epsilon = 1/32)
    logic [5:0] bip_counter;
    
    // Set assignment logic for Set Dueling Monitors (SDMs)
    logic is_srrip_leader, is_bip_leader, is_follower;
    logic use_srrip_policy;
    logic [RRPV_BITS-1:0] old_rrpv;
    
    // Victim selection FSM states
    typedef enum logic [2:0] {
        IDLE,
        SEARCH_VICTIM,
        AGE_ALL,
        VICTIM_FOUND
    } victim_state_t;
    
    victim_state_t victim_state, victim_next_state;
    
    // Internal signals - make these registered to hold the search results
    logic victim_found_reg, victim_found_comb;
    logic [3:0] selected_victim_way_reg, selected_victim_way_comb;
    
    // PSEL update control
    logic psel_updated;

    // Set assignment for Set Dueling (using hash of set_index)
    // Paper mentions 32 sets for each SDM
    always_comb begin
        // Simple assignment for demonstration - in real implementation would use hash
        is_srrip_leader = (set_index == 0 || set_index == 1);
        is_bip_leader = (set_index == 2 || set_index == 3);  
        is_follower = (set_index >= 4);
        
        // Policy selection based on PSEL counter
        if (is_srrip_leader)
            use_srrip_policy = 1'b1;
        else if (is_bip_leader)
            use_srrip_policy = 1'b0;
        else
            use_srrip_policy = (psel_reg >= PSEL_MID);  // Follower uses PSEL
    end
    
    // PSEL counter update (only for leader sets)
    always_ff @(posedge clk) begin
        if (rst) begin
            psel_reg <= PSEL_MID;
            psel_updated <= 1'b0;
        end else if (valid && miss && !psel_updated) begin  // Only update once per miss transaction
            // SRRIP leader set miss decrements PSEL (favors SRRIP when PSEL is low)
            if (is_srrip_leader && psel_reg > 0) begin
                psel_reg <= psel_reg - 1;
                psel_updated <= 1'b1;  // Mark as updated
                $display("Time %0t: PSEL decremented to %0d (SRRIP leader miss)", $time, psel_reg - 1);
            end
            // BIP leader set miss increments PSEL (favors BIP when PSEL is high)  
            else if (is_bip_leader && psel_reg < PSEL_MAX) begin
                psel_reg <= psel_reg + 1;
                psel_updated <= 1'b1;  // Mark as updated
                $display("Time %0t: PSEL incremented to %0d (BIP leader miss)", $time, psel_reg + 1);
            end
        end else if (!valid || !miss) begin
            // Reset the update flag when the miss transaction is complete
            psel_updated <= 1'b0;
        end
    end
    
    // BIP counter for epsilon probability (1/32 chance of inserting at RRPV_LONG)
    always_ff @(posedge clk) begin
        if (rst) begin
            bip_counter <= 0;
        end else if (valid && miss && !use_srrip_policy && victim_state == VICTIM_FOUND) begin
            // Only update when actually inserting a block
            bip_counter <= (bip_counter + 1) % BIP_EPSILON;
        end
    end
    
    // Hit promotion policy (SRRIP-FP from paper) and insertion policy
    always_ff @(posedge clk) begin
        if (rst) begin
            // Initialize all RRPV values to distant future
            for (int i = 0; i < NUM_SETS; i++) begin
                for (int j = 0; j < NUM_WAYS; j++) begin
                    rrpv_table[i][j] <= RRPV_MAX;
                end
            end
        end else if (valid && hit) begin
            // Hit Promotion: decrement RRPV (but not below 0)
            if (rrpv_table[set_index][access_way] > 0) begin
                rrpv_table[set_index][access_way] <= rrpv_table[set_index][access_way] - 1;
                $display("Time %0t: Hit on Set %0d Way %0d, RRPV decremented to %0d", $time, set_index, access_way, rrpv_table[set_index][access_way] - 1);
            end else begin
                $display("Time %0t: Hit on Set %0d Way %0d, RRPV already at minimum (0)", $time, set_index, access_way);
            end
        end else if (victim_state == VICTIM_FOUND && miss && valid) begin
            // Insert new block based on policy
            if (use_srrip_policy) begin
                // SRRIP: always insert with long re-reference interval
                rrpv_table[set_index][selected_victim_way_reg] <= RRPV_LONG;
                $display("Time %0t: SRRIP insertion - Set %0d Way %0d, RRPV set to %0d", $time, set_index, selected_victim_way_reg, RRPV_LONG);
            end else begin
                // BIP: insert with distant (probability 31/32) or long (probability 1/32)
                if (bip_counter == 0) begin
                    rrpv_table[set_index][selected_victim_way_reg] <= RRPV_LONG;
                    $display("Time %0t: BIP insertion (1/32) - Set %0d Way %0d, RRPV set to %0d", $time, set_index, selected_victim_way_reg, RRPV_LONG);
                end else begin
                    rrpv_table[set_index][selected_victim_way_reg] <= RRPV_MAX;
                    $display("Time %0t: BIP insertion (31/32) - Set %0d Way %0d, RRPV set to %0d", $time, set_index, selected_victim_way_reg, RRPV_MAX);
                end
            end
        end else if (victim_state == AGE_ALL) begin
            // Age all blocks in the set by incrementing RRPV (but not beyond RRPV_MAX)
            $display("Time %0t: *** AGING START *** for set %0d", $time, set_index);
            $display("Time %0t: Before aging - Set %0d: [%0d,%0d,%0d,%0d]", $time, set_index, 
                     rrpv_table[set_index][0], rrpv_table[set_index][1], 
                     rrpv_table[set_index][2], rrpv_table[set_index][3]);
            for (int i = 0; i < NUM_WAYS; i++) begin
                if (rrpv_table[set_index][i] < RRPV_MAX) begin
                    old_rrpv = rrpv_table[set_index][i];
                    rrpv_table[set_index][i] <= old_rrpv + 1;
                    $display("  Way %0d: RRPV %0d -> %0d", i, old_rrpv, old_rrpv + 1);
                end else begin
                    $display("  Way %0d: RRPV %0d (already at max)", i, rrpv_table[set_index][i]);
                end
            end
        end
    end
    
    // Combinational victim search logic 
    always_comb begin
        victim_found_comb = 1'b0;
        selected_victim_way_comb = 4'b0;
        
        // Search for first block with RRPV_MAX (distant re-reference)
        for (int i = 0; i < NUM_WAYS; i++) begin
            if (rrpv_table[set_index][i] == RRPV_MAX && !victim_found_comb) begin
                victim_found_comb = 1'b1;
                selected_victim_way_comb = i[3:0];
                break;
            end
        end
    end
    
    // Register the victim search results at the right time
    always_ff @(posedge clk) begin
        if (rst) begin
            victim_found_reg <= 1'b0;
            selected_victim_way_reg <= 4'b0;
        end else if (victim_state == SEARCH_VICTIM) begin
            // Capture search results when in SEARCH_VICTIM state
            victim_found_reg <= victim_found_comb;
            selected_victim_way_reg <= selected_victim_way_comb;
            $display("Time %0t: VICTIM SEARCH in set %0d - Current RRPVs: [%0d,%0d,%0d,%0d], victim_found=%b, selected_way=%0d", 
                     $time, set_index, 
                     rrpv_table[set_index][0], rrpv_table[set_index][1], 
                     rrpv_table[set_index][2], rrpv_table[set_index][3],
                     victim_found_comb, selected_victim_way_comb);
        end
        // NOTE: Do not capture search results in AGE_ALL.  The AGE_ALL state
        // only increments the RRPV counters.  The updated counters will be
        // evaluated when we transition back to SEARCH_VICTIM on the next
        // cycle (see FSM changes above).
        
        // No additional actions while in AGE_ALL.
    end
    
    // Debug: Print state after aging is committed
    always @(posedge clk) begin
        if (victim_state == AGE_ALL && !rst) begin
            // This happens after the aging is committed
            $display("Time %0t: *** AGING COMPLETE *** for set %0d", $time, set_index);
            $display("Time %0t: After aging - Set %0d: [%0d,%0d,%0d,%0d]", $time, set_index, 
                     rrpv_table[set_index][0], rrpv_table[set_index][1], 
                     rrpv_table[set_index][2], rrpv_table[set_index][3]);
        end
    end
    
    // Victim selection FSM
    always_ff @(posedge clk) begin
        if (rst) begin
            victim_state <= IDLE;
        end else begin
            victim_state <= victim_next_state;
            $display("Time %0t: FSM transition: %s -> %s", $time, victim_state.name(), victim_next_state.name());
        end
    end
    
    // FSM next state logic 
    always_comb begin
        case (victim_state)
            IDLE: begin
                if (valid && miss)
                    victim_next_state = SEARCH_VICTIM;
                else
                    victim_next_state = IDLE;
            end
            
            SEARCH_VICTIM: begin
              // Use the *fresh* combinational search result so that the FSM
              // reacts immediately in the same cycle.  Relying on
              // victim_found_reg introduces a one-cycle latency that breaks
              // the AGE-SEARCH handshake.
              if (!victim_found_comb)
                     victim_next_state = AGE_ALL;
                else
                    victim_next_state = VICTIM_FOUND;
            end
            
            AGE_ALL: begin
                // After aging, always re-enter SEARCH_VICTIM state so the
                // freshly-updated RRPV values are evaluated in a new cycle.
                // This prevents continually ageing the same set without ever
                // giving the SEARCH_VICTIM state a chance to see the new
                // counters.
                victim_next_state = SEARCH_VICTIM;
            end
            
            VICTIM_FOUND: begin
                victim_next_state = IDLE;
            end
            
            default: victim_next_state = IDLE;
        endcase
    end
    
    // Output assignments
    always_ff @(posedge clk) begin
        if (rst) begin
            victim_way <= 4'b0;
            victim_ready <= 1'b0;
        end else begin
            case (victim_state)
                VICTIM_FOUND: begin
                    victim_way <= selected_victim_way_reg;
                    victim_ready <= 1'b1;
                    $display("Time %0t: VICTIM READY - Way %0d selected for set %0d", $time, selected_victim_way_reg, set_index);
                end
                default: begin
                    victim_ready <= 1'b0;
                end
            endcase
        end
    end

endmodule
