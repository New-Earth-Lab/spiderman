using AstroImages
actu_map = Bool.(load("/mnt/datadrive/DATA/dm/BAX307-actu-map.fits"))
##
function limit_inter_actuator_stroke!(cmd_vec, actu_map, threshold)

end

limit_inter_actuator_stroke!(cmd_vec, actu_map, 0.1)

##


# function smooth_pass!(cmd_vec, actu_map, threshold, 
#                      i_range, j_range, neighbor_positions)
#     rows, cols = size(actu_map)
#     diag_threshold = threshold * √2
#     index_map = create_index_map(actu_map)
    
#     for i in i_range
#         for j in j_range
#             if !actu_map[i,j]
#                 continue
#             end
#             current_idx = index_map[i,j]
            
#             for (di, dj) in neighbor_positions
#                 ni, nj = i + di, j + dj
#                 if ni < 1 || ni > rows || nj < 1 || nj > cols || !actu_map[ni,nj]
#                     continue
#                 end
                
#                 neighbor_idx = index_map[ni,nj]
#                 curr_threshold = (abs(di) + abs(dj) == 2) ? diag_threshold : threshold
                
#                 diff = abs(cmd_vec[current_idx] - cmd_vec[neighbor_idx])
#                 if diff > curr_threshold
#                     midpoint = (cmd_vec[current_idx] + cmd_vec[neighbor_idx]) / 2
#                     delta = (diff - curr_threshold) / 2
#                     cmd_vec[current_idx] = cmd_vec[current_idx] > cmd_vec[neighbor_idx] ? 
#                                          midpoint - delta : midpoint + delta
#                     cmd_vec[neighbor_idx] = cmd_vec[neighbor_idx] > cmd_vec[current_idx] ? 
#                                           midpoint - delta : midpoint + delta
#                 end
#             end
#         end
#     end
# end

# function limit_inter_actuator_stroke!(cmd_vec, actu_map, threshold)
#     rows, cols = size(actu_map)
    
#     # Define scanning patterns
#     # row_major = (1:rows, 1:cols, [(0,1), (1,1), (1,0), (1,-1)])
#     # col_major = (1:rows, 1:cols, [(1,0), (1,1), (0,1), (-1,1)])
#     # reverse_row = (rows:-1:1, cols:-1:1, [(0,-1), (-1,-1), (-1,0), (-1,1)])
#     #= If we want to add other patterns later:
#     col_major = (1:rows, 1:cols, [(1,0), (1,1), (0,1), (-1,1)])
#     reverse_row = (rows:-1:1, cols:-1:1, [(0,-1), (-1,-1), (-1,0), (-1,1)])
#     =#

#     # row_major = 

#     # Check all 8 neighbors for each actuator
#     neighbor_positions =(1:rows, 1:cols,  [
#         (-1,-1), (-1,0), (-1,1),
#         (0,-1),          (0,1),
#         (1,-1),  (1,0),  (1,1)
#     ])
    
#     # Single pass with row-major scanning
#     # smooth_pass!(cmd_vec, actu_map, threshold, row_major...)
#     # smooth_pass!(cmd_vec, actu_map, threshold, col_major...)
#     # smooth_pass!(cmd_vec, actu_map, threshold, reverse_row...)
#     smooth_pass!(cmd_vec, actu_map, threshold, neighbor_positions...)
# end

##
function create_index_map(actu_map)
    index_map = zeros(Int, size(actu_map))
    current_idx = 1
    @time for i in 1:size(actu_map, 1)
        for j in 1:size(actu_map, 2)
            if actu_map[i,j]
                index_map[i,j] = current_idx
                current_idx += 1
            end
        end
    end
    return index_map
end
function limit_inter_actuator_stroke!(cmd_vec, actu_map, threshold)
    @showtime index_map = create_index_map(actu_map)
    display(index_map)

    # Smoothing passes
    @showtime smooth_horizontal!(index_map, cmd_vec, actu_map, threshold, true)   # Left to right
    @showtime smooth_horizontal!(index_map, cmd_vec, actu_map, threshold, false)  # Right to left
    @showtime smooth_vertical!(index_map, cmd_vec, actu_map, threshold, true)     # Top to bottom
    @showtime smooth_vertical!(index_map, cmd_vec, actu_map, threshold, false)    # Bottom to top
    
    # Hard clamping passes
    @showtime hard_clamp_horizontal!(index_map, cmd_vec, actu_map, threshold, true)
    @showtime hard_clamp_vertical!(index_map, cmd_vec, actu_map, threshold, true)
end
function smooth_horizontal!(index_map, cmd_vec, actu_map, threshold, left_to_right=true)
    rows, cols = size(actu_map)
    
    for i in 1:rows
        j_range = left_to_right ? (1:cols) : (cols:-1:1)
        for j in j_range
            if !actu_map[i,j]
                continue
            end
            # Check only horizontal neighbor
            nj = left_to_right ? j + 1 : j - 1
            if nj < 1 || nj > cols || !actu_map[i,nj]
                continue
            end
            
            current_idx = index_map[i,j]
            neighbor_idx = index_map[i,nj]
            
            diff = abs(cmd_vec[current_idx] - cmd_vec[neighbor_idx])
            if diff > threshold
                midpoint = (cmd_vec[current_idx] + cmd_vec[neighbor_idx]) / 2
                delta = (diff - threshold) / 2
                cmd_vec[current_idx] = cmd_vec[current_idx] > cmd_vec[neighbor_idx] ? 
                                     midpoint - delta : midpoint + delta
                cmd_vec[neighbor_idx] = cmd_vec[neighbor_idx] > cmd_vec[current_idx] ? 
                                      midpoint - delta : midpoint + delta
            end
        end
    end
end

function smooth_vertical!(index_map, cmd_vec, actu_map, threshold, top_to_bottom=true)
    rows, cols = size(actu_map)
    
    i_range = top_to_bottom ? (1:rows) : (rows:-1:1)
    for j in 1:cols
        for i in i_range
            if !actu_map[i,j]
                continue
            end
            # Check only vertical neighbor
            ni = top_to_bottom ? i + 1 : i - 1
            if ni < 1 || ni > rows || !actu_map[ni,j]
                continue
            end
            
            current_idx = index_map[i,j]
            neighbor_idx = index_map[ni,j]
            
            diff = abs(cmd_vec[current_idx] - cmd_vec[neighbor_idx])
            if diff > threshold
                midpoint = (cmd_vec[current_idx] + cmd_vec[neighbor_idx]) / 2
                delta = (diff - threshold) / 2
                cmd_vec[current_idx] = cmd_vec[current_idx] > cmd_vec[neighbor_idx] ? 
                                     midpoint - delta : midpoint + delta
                cmd_vec[neighbor_idx] = cmd_vec[neighbor_idx] > cmd_vec[current_idx] ? 
                                      midpoint - delta : midpoint + delta
            end
        end
    end
end
function hard_clamp_horizontal!(index_map, cmd_vec, actu_map, threshold, left_to_right=true)
    rows, cols = size(actu_map)
    
    for i in 1:rows
        j_range = left_to_right ? (1:cols) : (cols:-1:1)
        for j in j_range
            if !actu_map[i,j]
                continue
            end
            # Check horizontal neighbor
            nj = left_to_right ? j + 1 : j - 1
            if nj < 1 || nj > cols || !actu_map[i,nj]
                continue
            end
            
            current_idx = index_map[i,j]
            neighbor_idx = index_map[i,nj]
            
            diff = cmd_vec[neighbor_idx] - cmd_vec[current_idx]
            if abs(diff) > threshold
                # Keep current_idx value, clamp neighbor_idx value
                cmd_vec[neighbor_idx] = cmd_vec[current_idx] + sign(diff) * threshold
            end
        end
    end
end

function hard_clamp_vertical!(index_map, cmd_vec, actu_map, threshold, top_to_bottom=true)
    rows, cols = size(actu_map)
    
    i_range = top_to_bottom ? (1:rows) : (rows:-1:1)
    for j in 1:cols
        for i in i_range
            if !actu_map[i,j]
                continue
            end
            # Check vertical neighbor
            ni = top_to_bottom ? i + 1 : i - 1
            if ni < 1 || ni > rows || !actu_map[ni,j]
                continue
            end
            
            current_idx = index_map[i,j]
            neighbor_idx = index_map[ni,j]
            
            diff = cmd_vec[neighbor_idx] - cmd_vec[current_idx]
            if abs(diff) > threshold
                # Keep current_idx value, clamp neighbor_idx value
                cmd_vec[neighbor_idx] = cmd_vec[current_idx] + sign(diff) * threshold
            end
        end
    end
end
##
actu_map = Bool.(load("/mnt/datadrive/DATA/dm/BAX307-actu-map.fits"))
cmd_vec = randn(468)
cmd_vec = collect(load("/mnt/datadrive/DATA/dm/bestflat.fits"))
n = 250
# splice!(cmd_vec, n)
# actu_map[findall(actu_map)[n]] = 0
cmd_vec[n+1] = maximum(cmd_vec)*4

out = zeros(size(actu_map))
out[actu_map] .= cmd_vec
imview(out)
##
limit_inter_actuator_stroke!(cmd_vec, actu_map, 0.2)
out2 = zeros(size(actu_map))
out2[actu_map] .= cmd_vec

imview([out; out2])
##
imview(out .- out2)