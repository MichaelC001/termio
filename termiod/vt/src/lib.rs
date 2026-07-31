//! Safe, engine-neutral snapshot boundary over libghostty-vt.

use std::ffi::c_void;
use std::fmt;
use std::marker::PhantomData;
use std::mem;
use std::ptr;
use std::rc::Rc;

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

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub codepoint: u32,
    pub foreground: Rgb,
    pub background: Rgb,
    pub attributes: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub alt_screen: bool,
    /// OSC 0/2 title reported by libghostty-vt, if one was set.
    pub title: Option<String>,
    pub cells: Vec<Cell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scrollback {
    pub total_rows: usize,
    /// Rows ordered newest-first, starting immediately above the viewport.
    pub rows: Vec<Vec<Cell>>,
}

#[derive(Debug, Clone)]
pub struct VtError(String);

impl fmt::Display for VtError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for VtError {}

type Result<T> = std::result::Result<T, VtError>;

fn check(result: ffi::GhosttyResult, operation: &str) -> Result<()> {
    if result == ffi::GhosttyResult_GHOSTTY_SUCCESS {
        Ok(())
    } else {
        Err(VtError(format!(
            "{operation} failed with GhosttyResult {result}"
        )))
    }
}

/// A terminal plus reusable render iterators. This type is deliberately
/// `!Send`/`!Sync`; construct and use it on the sidecar thread that owns it.
pub struct VtTerminal {
    terminal: ffi::GhosttyTerminal,
    render_state: ffi::GhosttyRenderState,
    row_iterator: ffi::GhosttyRenderStateRowIterator,
    row_cells: ffi::GhosttyRenderStateRowCells,
    _thread_confined: PhantomData<Rc<()>>,
}

impl VtTerminal {
    pub fn new(rows: u16, cols: u16) -> Result<Self> {
        let mut value = Self {
            terminal: ptr::null_mut(),
            render_state: ptr::null_mut(),
            row_iterator: ptr::null_mut(),
            row_cells: ptr::null_mut(),
            _thread_confined: PhantomData,
        };
        let options = ffi::GhosttyTerminalOptions {
            cols,
            rows,
            max_scrollback: 1_000,
        };

        // SAFETY: Every out pointer refers to owned storage in `value`; null
        // allocators select libghostty-vt's default allocator.
        unsafe {
            check(
                ffi::ghostty_terminal_new(ptr::null(), &mut value.terminal, options),
                "ghostty_terminal_new",
            )?;
            check(
                ffi::ghostty_render_state_new(ptr::null(), &mut value.render_state),
                "ghostty_render_state_new",
            )?;
            check(
                ffi::ghostty_render_state_row_iterator_new(ptr::null(), &mut value.row_iterator),
                "ghostty_render_state_row_iterator_new",
            )?;
            check(
                ffi::ghostty_render_state_row_cells_new(ptr::null(), &mut value.row_cells),
                "ghostty_render_state_row_cells_new",
            )?;
        }
        Ok(value)
    }

    pub fn vt_write(&mut self, bytes: &[u8]) {
        // SAFETY: The byte slice remains valid for this synchronous call and
        // the terminal is exclusively borrowed on its owner thread.
        unsafe {
            ffi::ghostty_terminal_vt_write(self.terminal, bytes.as_ptr(), bytes.len());
        }
    }

    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        // Pixel dimensions are not used by the daemon snapshot sidecar; fixed
        // cell metrics still give libghostty-vt consistent total dimensions.
        let result = unsafe { ffi::ghostty_terminal_resize(self.terminal, cols, rows, 8, 16) };
        check(result, "ghostty_terminal_resize")
    }

    pub fn snapshot(&mut self) -> Result<Snapshot> {
        // SAFETY: Both handles are live and exclusively owned here.
        unsafe {
            check(
                ffi::ghostty_render_state_update(self.render_state, self.terminal),
                "ghostty_render_state_update",
            )?;
        }

        let rows = self.terminal_u16(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ROWS)?;
        let cols = self.terminal_u16(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS)?;
        let cursor_x =
            self.terminal_u16(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_X)?;
        let cursor_y =
            self.terminal_u16(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_CURSOR_Y)?;
        let alt_screen =
            self.active_screen()? == ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
        let title = self.title()?;
        let foreground = self.terminal_rgb(
            ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
            Rgb {
                r: 255,
                g: 255,
                b: 255,
            },
        )?;
        let background = self.terminal_rgb(
            ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
            Rgb::default(),
        )?;

        self.populate_rows()?;
        let expected = usize::from(rows) * usize::from(cols);
        let mut cells = Vec::with_capacity(expected);

        // SAFETY: Iterators were populated from the live immutable render
        // state, and remain valid until the next render-state update.
        unsafe {
            while ffi::ghostty_render_state_row_iterator_next(self.row_iterator) {
                check(
                    ffi::ghostty_render_state_row_get(
                        self.row_iterator,
                        ffi::GhosttyRenderStateRowData_GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                        (&mut self.row_cells as *mut ffi::GhosttyRenderStateRowCells)
                            .cast::<c_void>(),
                    ),
                    "ghostty_render_state_row_get(cells)",
                )?;

                while ffi::ghostty_render_state_row_cells_next(self.row_cells) {
                    cells.push(self.current_cell(foreground, background)?);
                }
            }
        }

        if cells.len() != expected {
            return Err(VtError(format!(
                "render grid contained {} cells, expected {expected}",
                cells.len()
            )));
        }

        Ok(Snapshot {
            rows,
            cols,
            cursor_x,
            cursor_y,
            alt_screen,
            title,
            cells,
        })
    }

    /// Copy at most `max_rows` rows of primary-screen history, newest-first.
    /// Callers must invoke this in the same serialized boundary as `snapshot`
    /// if the two results need to describe one terminal state.
    pub fn scrollback(&self, max_rows: usize) -> Result<Scrollback> {
        let total_rows =
            self.terminal_usize(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)?;
        let capture_rows = total_rows.min(max_rows);
        if capture_rows == 0 {
            return Ok(Scrollback {
                total_rows,
                rows: Vec::new(),
            });
        }

        let cols = self.terminal_u16(ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLS)?;
        let default_fg = self.terminal_rgb(
            ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND,
            Rgb {
                r: 255,
                g: 255,
                b: 255,
            },
        )?;
        let default_bg = self.terminal_rgb(
            ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND,
            Rgb::default(),
        )?;
        let palette = self.terminal_palette()?;
        let first_row = total_rows - capture_rows;
        let mut rows = Vec::with_capacity(capture_rows);

        for y in (first_row..total_rows).rev() {
            let y = u32::try_from(y)
                .map_err(|_| VtError("scrollback row exceeds u32 coordinate space".to_string()))?;
            let mut row = Vec::with_capacity(usize::from(cols));
            for x in 0..cols {
                row.push(self.history_cell(x, y, default_fg, default_bg, &palette)?);
            }
            rows.push(row);
        }

        Ok(Scrollback { total_rows, rows })
    }

    fn populate_rows(&mut self) -> Result<()> {
        let result = unsafe {
            ffi::ghostty_render_state_get(
                self.render_state,
                ffi::GhosttyRenderStateData_GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                (&mut self.row_iterator as *mut ffi::GhosttyRenderStateRowIterator)
                    .cast::<c_void>(),
            )
        };
        check(result, "ghostty_render_state_get(row iterator)")
    }

    fn current_cell(&mut self, default_fg: Rgb, default_bg: Rgb) -> Result<Cell> {
        let mut raw_cell = ffi::GhosttyCell::default();
        let raw_result = unsafe {
            ffi::ghostty_render_state_row_cells_get(
                self.row_cells,
                ffi::GhosttyRenderStateRowCellsData_GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                (&mut raw_cell as *mut ffi::GhosttyCell).cast::<c_void>(),
            )
        };
        check(raw_result, "ghostty_render_state_row_cells_get(raw)")?;

        let mut codepoint = 0u32;
        let codepoint_result = unsafe {
            ffi::ghostty_cell_get(
                raw_cell,
                ffi::GhosttyCellData_GHOSTTY_CELL_DATA_CODEPOINT,
                (&mut codepoint as *mut u32).cast::<c_void>(),
            )
        };
        check(codepoint_result, "ghostty_cell_get(codepoint)")?;

        Ok(Cell {
            codepoint,
            foreground: self.cell_rgb(
                ffi::GhosttyRenderStateRowCellsData_GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                default_fg,
            )?,
            background: self.cell_rgb(
                ffi::GhosttyRenderStateRowCellsData_GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                default_bg,
            )?,
            // Phase 1a needs text and colors. Attribute mapping remains owned
            // by this boundary and can fill these protocol bits additively.
            attributes: 0,
        })
    }

    fn cell_rgb(&self, field: ffi::GhosttyRenderStateRowCellsData, fallback: Rgb) -> Result<Rgb> {
        let mut color = ffi::GhosttyColorRgb::default();
        let result = unsafe {
            ffi::ghostty_render_state_row_cells_get(
                self.row_cells,
                field,
                (&mut color as *mut ffi::GhosttyColorRgb).cast::<c_void>(),
            )
        };
        if matches!(
            result,
            ffi::GhosttyResult_GHOSTTY_INVALID_VALUE | ffi::GhosttyResult_GHOSTTY_NO_VALUE
        ) {
            return Ok(fallback);
        }
        check(result, "ghostty_render_state_row_cells_get(color)")?;
        Ok(rgb(color))
    }

    fn terminal_u16(&self, field: ffi::GhosttyTerminalData) -> Result<u16> {
        let mut value = 0u16;
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.terminal,
                field,
                (&mut value as *mut u16).cast::<c_void>(),
            )
        };
        check(result, "ghostty_terminal_get(u16)")?;
        Ok(value)
    }

    fn terminal_usize(&self, field: ffi::GhosttyTerminalData) -> Result<usize> {
        let mut value = 0usize;
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.terminal,
                field,
                (&mut value as *mut usize).cast::<c_void>(),
            )
        };
        check(result, "ghostty_terminal_get(usize)")?;
        Ok(value)
    }

    fn terminal_palette(&self) -> Result<[Rgb; 256]> {
        let mut raw = [ffi::GhosttyColorRgb::default(); 256];
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.terminal,
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_COLOR_PALETTE,
                raw.as_mut_ptr().cast::<c_void>(),
            )
        };
        check(result, "ghostty_terminal_get(palette)")?;
        Ok(raw.map(rgb))
    }

    fn history_cell(
        &self,
        x: u16,
        y: u32,
        default_fg: Rgb,
        default_bg: Rgb,
        palette: &[Rgb; 256],
    ) -> Result<Cell> {
        let point = ffi::GhosttyPoint {
            tag: ffi::GhosttyPointTag_GHOSTTY_POINT_TAG_HISTORY,
            value: ffi::GhosttyPointValue {
                coordinate: ffi::GhosttyPointCoordinate { x, y },
            },
        };
        let mut reference = ffi::GhosttyGridRef {
            size: mem::size_of::<ffi::GhosttyGridRef>(),
            ..Default::default()
        };
        let mut raw_cell = ffi::GhosttyCell::default();
        let mut style = ffi::GhosttyStyle {
            size: mem::size_of::<ffi::GhosttyStyle>(),
            ..Default::default()
        };

        unsafe {
            check(
                ffi::ghostty_terminal_grid_ref(self.terminal, point, &mut reference),
                "ghostty_terminal_grid_ref(history)",
            )?;
            check(
                ffi::ghostty_grid_ref_cell(&reference, &mut raw_cell),
                "ghostty_grid_ref_cell(history)",
            )?;
            check(
                ffi::ghostty_grid_ref_style(&reference, &mut style),
                "ghostty_grid_ref_style(history)",
            )?;
        }

        let mut codepoint = 0u32;
        let mut content_tag = ffi::GhosttyCellContentTag_GHOSTTY_CELL_CONTENT_CODEPOINT;
        unsafe {
            check(
                ffi::ghostty_cell_get(
                    raw_cell,
                    ffi::GhosttyCellData_GHOSTTY_CELL_DATA_CODEPOINT,
                    (&mut codepoint as *mut u32).cast::<c_void>(),
                ),
                "ghostty_cell_get(history codepoint)",
            )?;
            check(
                ffi::ghostty_cell_get(
                    raw_cell,
                    ffi::GhosttyCellData_GHOSTTY_CELL_DATA_CONTENT_TAG,
                    (&mut content_tag as *mut ffi::GhosttyCellContentTag).cast::<c_void>(),
                ),
                "ghostty_cell_get(history content tag)",
            )?;
        }

        let mut foreground = style_color(style.fg_color, default_fg, palette);
        let mut background = style_color(style.bg_color, default_bg, palette);
        match content_tag {
            ffi::GhosttyCellContentTag_GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE => {
                let mut index = 0u8;
                unsafe {
                    check(
                        ffi::ghostty_cell_get(
                            raw_cell,
                            ffi::GhosttyCellData_GHOSTTY_CELL_DATA_COLOR_PALETTE,
                            (&mut index as *mut u8).cast::<c_void>(),
                        ),
                        "ghostty_cell_get(history background palette)",
                    )?;
                }
                background = palette[usize::from(index)];
            }
            ffi::GhosttyCellContentTag_GHOSTTY_CELL_CONTENT_BG_COLOR_RGB => {
                let mut color = ffi::GhosttyColorRgb::default();
                unsafe {
                    check(
                        ffi::ghostty_cell_get(
                            raw_cell,
                            ffi::GhosttyCellData_GHOSTTY_CELL_DATA_COLOR_RGB,
                            (&mut color as *mut ffi::GhosttyColorRgb).cast::<c_void>(),
                        ),
                        "ghostty_cell_get(history background rgb)",
                    )?;
                }
                background = rgb(color);
            }
            _ => {}
        }
        if style.inverse {
            mem::swap(&mut foreground, &mut background);
        }
        if style.invisible {
            codepoint = 0;
        }

        Ok(Cell {
            codepoint,
            foreground,
            background,
            // Attribute mapping is shared with viewport snapshots and remains
            // reserved for a later additive wire-format extension.
            attributes: 0,
        })
    }

    fn terminal_rgb(&self, field: ffi::GhosttyTerminalData, fallback: Rgb) -> Result<Rgb> {
        let mut value = ffi::GhosttyColorRgb::default();
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.terminal,
                field,
                (&mut value as *mut ffi::GhosttyColorRgb).cast::<c_void>(),
            )
        };
        if result == ffi::GhosttyResult_GHOSTTY_NO_VALUE {
            return Ok(fallback);
        }
        check(result, "ghostty_terminal_get(rgb)")?;
        Ok(rgb(value))
    }

    fn active_screen(&self) -> Result<ffi::GhosttyTerminalScreen> {
        let mut value = ffi::GhosttyTerminalScreen_GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.terminal,
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
                (&mut value as *mut ffi::GhosttyTerminalScreen).cast::<c_void>(),
            )
        };
        check(result, "ghostty_terminal_get(active screen)")?;
        Ok(value)
    }

    fn title(&self) -> Result<Option<String>> {
        let mut value = ffi::GhosttyString::default();
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.terminal,
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_TITLE,
                (&mut value as *mut ffi::GhosttyString).cast::<c_void>(),
            )
        };
        if result == ffi::GhosttyResult_GHOSTTY_NO_VALUE {
            return Ok(None);
        }
        check(result, "ghostty_terminal_get(title)")?;
        if value.ptr.is_null() || value.len == 0 {
            return Ok(None);
        }
        // SAFETY: TITLE is borrowed from the terminal and is valid until the
        // next terminal mutation; we copy it before returning.
        let bytes = unsafe { std::slice::from_raw_parts(value.ptr, value.len) };
        Ok(Some(String::from_utf8_lossy(bytes).into_owned()))
    }
}

impl Drop for VtTerminal {
    fn drop(&mut self) {
        // SAFETY: The C API accepts null handles and every non-null handle is
        // uniquely owned by this wrapper.
        unsafe {
            ffi::ghostty_render_state_row_cells_free(self.row_cells);
            ffi::ghostty_render_state_row_iterator_free(self.row_iterator);
            ffi::ghostty_render_state_free(self.render_state);
            ffi::ghostty_terminal_free(self.terminal);
        }
    }
}

fn rgb(value: ffi::GhosttyColorRgb) -> Rgb {
    Rgb {
        r: value.r,
        g: value.g,
        b: value.b,
    }
}

fn style_color(color: ffi::GhosttyStyleColor, fallback: Rgb, palette: &[Rgb; 256]) -> Rgb {
    match color.tag {
        ffi::GhosttyStyleColorTag_GHOSTTY_STYLE_COLOR_PALETTE => {
            // SAFETY: The tag identifies the active union field.
            palette[usize::from(unsafe { color.value.palette })]
        }
        ffi::GhosttyStyleColorTag_GHOSTTY_STYLE_COLOR_RGB => {
            // SAFETY: The tag identifies the active union field.
            rgb(unsafe { color.value.rgb })
        }
        _ => fallback,
    }
}

#[cfg(test)]
mod tests {
    use super::VtTerminal;

    #[test]
    fn snapshots_text_color_cursor_and_title() {
        let mut terminal = VtTerminal::new(2, 8).unwrap();
        terminal.vt_write(b"\x1b]2;proof\x07\x1b[31mRED\x1b[0m");
        let snapshot = terminal.snapshot().unwrap();

        assert_eq!((snapshot.rows, snapshot.cols), (2, 8));
        assert_eq!((snapshot.cursor_x, snapshot.cursor_y), (3, 0));
        assert_eq!(snapshot.title.as_deref(), Some("proof"));
        assert_eq!(snapshot.cells[0].codepoint, u32::from('R'));
        assert_ne!(snapshot.cells[0].foreground, snapshot.cells[0].background);
    }

    #[test]
    fn snapshot_without_osc_title_is_valid() {
        let mut terminal = VtTerminal::new(1, 4).unwrap();
        terminal.vt_write(b"text");

        assert_eq!(terminal.snapshot().unwrap().title, None);
    }

    #[test]
    fn scrollback_rows_are_newest_first_and_bounded() {
        let mut terminal = VtTerminal::new(2, 16).unwrap();
        terminal.vt_write(b"ROW0\r\nROW1\r\nROW2\r\nROW3");

        let scrollback = terminal.scrollback(1).unwrap();
        assert_eq!(scrollback.total_rows, 2);
        assert_eq!(scrollback.rows.len(), 1);
        let text: String = scrollback.rows[0]
            .iter()
            .map(|cell| char::from_u32(cell.codepoint).unwrap_or(' '))
            .collect();
        assert!(text.starts_with("ROW1"));
    }
}
