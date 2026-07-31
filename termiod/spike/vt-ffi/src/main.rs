use std::ffi::c_void;
use std::ptr;

#[allow(
    dead_code,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    clippy::all,
    rustdoc::all
)]
mod ffi {
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

type ProofResult<T> = Result<T, String>;

fn check(result: ffi::GhosttyResult, operation: &str) -> ProofResult<()> {
    if result == ffi::GhosttyResult_GHOSTTY_SUCCESS {
        Ok(())
    } else {
        Err(format!("{operation} failed with GhosttyResult {result}"))
    }
}

struct Handles {
    terminal: ffi::GhosttyTerminal,
    render_state: ffi::GhosttyRenderState,
    row_iterator: ffi::GhosttyRenderStateRowIterator,
    row_cells: ffi::GhosttyRenderStateRowCells,
}

impl Default for Handles {
    fn default() -> Self {
        Self {
            terminal: ptr::null_mut(),
            render_state: ptr::null_mut(),
            row_iterator: ptr::null_mut(),
            row_cells: ptr::null_mut(),
        }
    }
}

impl Drop for Handles {
    fn drop(&mut self) {
        // SAFETY: The C API permits freeing null handles, and every non-null handle is owned here.
        unsafe {
            ffi::ghostty_render_state_row_cells_free(self.row_cells);
            ffi::ghostty_render_state_row_iterator_free(self.row_iterator);
            ffi::ghostty_render_state_free(self.render_state);
            ffi::ghostty_terminal_free(self.terminal);
        }
    }
}

fn terminal_u16(
    terminal: ffi::GhosttyTerminal,
    field: ffi::GhosttyTerminalData,
) -> ProofResult<u16> {
    let mut value = 0u16;
    // SAFETY: value has the u16 type required by the selected terminal field.
    let result = unsafe {
        ffi::ghostty_terminal_get(terminal, field, (&mut value as *mut u16).cast::<c_void>())
    };
    check(result, "ghostty_terminal_get(u16)")?;
    Ok(value)
}

fn terminal_screen(terminal: ffi::GhosttyTerminal) -> ProofResult<ffi::GhosttyTerminalScreen> {
    let mut value = ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    // SAFETY: value has the enum storage required by ACTIVE_SCREEN.
    let result = unsafe {
        ffi::ghostty_terminal_get(
            terminal,
            ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
            (&mut value as *mut ffi::GhosttyTerminalScreen).cast::<c_void>(),
        )
    };
    check(result, "ghostty_terminal_get(active screen)")?;
    Ok(value)
}

fn populate_rows(handles: &mut Handles) -> ProofResult<()> {
    // SAFETY: The row iterator is live and is populated by the live render state.
    let result = unsafe {
        ffi::ghostty_render_state_get(
            handles.render_state,
            ffi::GhosttyRenderStateData_GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            (&mut handles.row_iterator as *mut ffi::GhosttyRenderStateRowIterator).cast::<c_void>(),
        )
    };
    check(result, "ghostty_render_state_get(row iterator)")
}

fn clear_damage(handles: &mut Handles) -> ProofResult<()> {
    populate_rows(handles)?;
    // SAFETY: The populated iterator remains valid until the next render-state update.
    unsafe {
        while ffi::ghostty_render_state_row_iterator_next(handles.row_iterator) {
            let dirty = false;
            check(
                ffi::ghostty_render_state_row_set(
                    handles.row_iterator,
                    ffi::GhosttyRenderStateRowOption_GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                    (&dirty as *const bool).cast::<c_void>(),
                ),
                "ghostty_render_state_row_set(clean)",
            )?;
        }

        let clean = ffi::GhosttyRenderStateDirty_GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        check(
            ffi::ghostty_render_state_set(
                handles.render_state,
                ffi::GhosttyRenderStateOption_GHOSTTY_RENDER_STATE_OPTION_DIRTY,
                (&clean as *const ffi::GhosttyRenderStateDirty).cast::<c_void>(),
            ),
            "ghostty_render_state_set(clean)",
        )
    }
}

fn current_cell_text(cells: ffi::GhosttyRenderStateRowCells) -> ProofResult<char> {
    let mut raw_cell = 0;
    // SAFETY: raw_cell has the GhosttyCell storage required by RAW.
    unsafe {
        check(
            ffi::ghostty_render_state_row_cells_get(
                cells,
                ffi::GhosttyRenderStateRowCellsData_GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                (&mut raw_cell as *mut ffi::GhosttyCell).cast::<c_void>(),
            ),
            "ghostty_render_state_row_cells_get(raw)",
        )?;
    }

    let mut codepoint = 0u32;
    // SAFETY: codepoint has the u32 storage required by CODEPOINT.
    unsafe {
        check(
            ffi::ghostty_cell_get(
                raw_cell,
                ffi::GhosttyCellData_GHOSTTY_CELL_DATA_CODEPOINT,
                (&mut codepoint as *mut u32).cast::<c_void>(),
            ),
            "ghostty_cell_get(codepoint)",
        )?;
    }

    Ok(if codepoint == 0 {
        ' '
    } else {
        char::from_u32(codepoint).unwrap_or('\u{fffd}')
    })
}

fn snapshot(handles: &mut Handles) -> ProofResult<(Vec<usize>, Vec<String>, ffi::GhosttyColorRgb)> {
    populate_rows(handles)?;
    let mut dirty_rows = Vec::new();
    let mut grid = Vec::new();
    let mut green = ffi::GhosttyColorRgb::default();
    let mut row = 0usize;

    // SAFETY: Row and cell iterators are populated from the live, immutable render state.
    unsafe {
        while ffi::ghostty_render_state_row_iterator_next(handles.row_iterator) {
            let mut dirty = false;
            check(
                ffi::ghostty_render_state_row_get(
                    handles.row_iterator,
                    ffi::GhosttyRenderStateRowData_GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                    (&mut dirty as *mut bool).cast::<c_void>(),
                ),
                "ghostty_render_state_row_get(dirty)",
            )?;
            if dirty {
                dirty_rows.push(row);
            }

            check(
                ffi::ghostty_render_state_row_get(
                    handles.row_iterator,
                    ffi::GhosttyRenderStateRowData_GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                    (&mut handles.row_cells as *mut ffi::GhosttyRenderStateRowCells)
                        .cast::<c_void>(),
                ),
                "ghostty_render_state_row_get(cells)",
            )?;

            let mut line = String::new();
            let mut column = 0usize;
            while ffi::ghostty_render_state_row_cells_next(handles.row_cells) {
                line.push(current_cell_text(handles.row_cells)?);
                if row == 0 && column == 4 {
                    check(
                        ffi::ghostty_render_state_row_cells_get(
                            handles.row_cells,
                            ffi::GhosttyRenderStateRowCellsData_GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                            (&mut green as *mut ffi::GhosttyColorRgb).cast::<c_void>(),
                        ),
                        "ghostty_render_state_row_cells_get(fg color)",
                    )?;
                }
                column += 1;
            }
            grid.push(line);
            row += 1;
        }
    }

    Ok((dirty_rows, grid, green))
}

fn main() -> ProofResult<()> {
    let mut handles = Handles::default();
    let options = ffi::GhosttyTerminalOptions {
        cols: 12,
        rows: 4,
        max_scrollback: 100,
    };

    // SAFETY: All out pointers are valid; null allocators select Ghostty's default allocator.
    unsafe {
        check(
            ffi::ghostty_terminal_new(ptr::null(), &mut handles.terminal, options),
            "ghostty_terminal_new",
        )?;
        check(
            ffi::ghostty_render_state_new(ptr::null(), &mut handles.render_state),
            "ghostty_render_state_new",
        )?;
        check(
            ffi::ghostty_render_state_row_iterator_new(ptr::null(), &mut handles.row_iterator),
            "ghostty_render_state_row_iterator_new",
        )?;
        check(
            ffi::ghostty_render_state_row_cells_new(ptr::null(), &mut handles.row_cells),
            "ghostty_render_state_row_cells_new",
        )?;

        let initial =
            b"primary plain \x1b[31mRED\x1b[0m\x1b[?1049h\x1b[2J\x1b[HALT \x1b[32mGREEN\x1b[0m";
        ffi::ghostty_terminal_vt_write(handles.terminal, initial.as_ptr(), initial.len());
        check(
            ffi::ghostty_terminal_resize(handles.terminal, 16, 5, 8, 16),
            "ghostty_terminal_resize",
        )?;

        let position = b"\x1b[2;1H";
        ffi::ghostty_terminal_vt_write(handles.terminal, position.as_ptr(), position.len());
        check(
            ffi::ghostty_render_state_update(handles.render_state, handles.terminal),
            "ghostty_render_state_update(baseline)",
        )?;
    }

    clear_damage(&mut handles)?;

    // SAFETY: The terminal and render-state handles remain live and exclusively owned.
    unsafe {
        let final_write = b"\x1b[34mblue\x1b[0m";
        ffi::ghostty_terminal_vt_write(handles.terminal, final_write.as_ptr(), final_write.len());
        check(
            ffi::ghostty_render_state_update(handles.render_state, handles.terminal),
            "ghostty_render_state_update(final)",
        )?;
    }

    let columns = terminal_u16(
        handles.terminal,
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS,
    )?;
    let rows = terminal_u16(
        handles.terminal,
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS,
    )?;
    let cursor_x = terminal_u16(
        handles.terminal,
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X,
    )?;
    let cursor_y = terminal_u16(
        handles.terminal,
        ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y,
    )?;
    let alternate = terminal_screen(handles.terminal)?
        == ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    let (dirty_rows, grid, green) = snapshot(&mut handles)?;

    println!("engine=libghostty-vt");
    println!("dims={columns}x{rows}");
    println!("cursor=({cursor_x}, {cursor_y})");
    println!("alt_screen={alternate}");
    println!("dirty_rows={dirty_rows:?}");
    println!("green_cell_fg=rgb({}, {}, {})", green.r, green.g, green.b);
    println!("grid:");
    for (row, text) in grid.iter().enumerate() {
        println!("{row:02} |{text}|");
    }

    Ok(())
}
