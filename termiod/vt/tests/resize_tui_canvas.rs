use termiod_vt::VtTerminal;

/// A TUI's input box, drawn the way an agent draws one: a rule, a prompt row,
/// a rule. Explicitly positioned rows, no flowing text.
fn draw_box(vt: &mut VtTerminal, cols: usize) {
    let rule: String = "─".repeat(cols);
    vt.vt_write(b"\x1b[2J\x1b[H");
    vt.vt_write(format!("\x1b[1;1H{rule}").as_bytes());
    vt.vt_write(b"\x1b[2;1H\xe2\x9d\xaf ");
    vt.vt_write(format!("\x1b[3;1H{rule}").as_bytes());
}

#[test]
fn a_drag_that_narrows_then_widens_a_tui_canvas() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    draw_box(&mut vt, 74);
    println!("--- drawn at 74 ---");
    println!("{}", vt.screen_text().expect("text"));

    // The drag: in to 55, then out to 74, the way the trace recorded it.
    for cols in [63u16, 55, 62, 72, 74] {
        vt.resize_reflowing(24, cols).expect("resize");
    }
    println!("--- after narrow-then-widen, no repaint from the child ---");
    println!("{}", vt.screen_text().expect("text"));
}

#[test]
fn the_same_drag_with_a_repaint_at_the_end() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    draw_box(&mut vt, 74);
    for cols in [63u16, 55, 62, 72, 74] {
        vt.resize_reflowing(24, cols).expect("resize");
    }
    // What the child does when it finally answers: redraw at the new width.
    draw_box(&mut vt, 74);
    println!("--- after the child repaints ---");
    println!("{}", vt.screen_text().expect("text"));
}

/// What a full-screen TUI does when it answers SIGWINCH: walk the cursor back
/// up over the rows it believes it drew, erase from there down, redraw. The
/// row count comes from the app's own model of the screen, which is a model of
/// the width it drew at — not of what the terminal did to those rows since.
fn child_winch_redraw(vt: &mut VtTerminal, own_rows: usize, cols: usize) {
    vt.vt_write(format!("\x1b[{own_rows}A").as_bytes());
    vt.vt_write(b"\r\x1b[J");
    let rule: String = "─".repeat(cols);
    vt.vt_write(format!("{rule}\r\n").as_bytes());
    vt.vt_write(b"\xe2\x9d\xaf \r\n");
    vt.vt_write(format!("{rule}").as_bytes());
}

/// Negative control: unconditional reflow makes the
/// engine rewraps the box into more physical rows than the app drew — and the
/// app then walks back up by the count it *drew*, erases from there, and
/// leaves whatever sat above it on screen.
#[test]
fn a_reflowing_resize_strands_the_rows_the_child_does_not_know_it_has() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    vt.vt_write(b"\x1b[?7h");
    draw_box(&mut vt, 74);
    vt.resize_reflowing(24, 55).expect("resize");
    child_winch_redraw(&mut vt, 2, 55);
    let text = vt.screen_text().expect("text");
    println!("--- reflowing resize, child redraws ---\n{text}");
    let rules = text.lines().filter(|l| l.starts_with('─')).count();
    assert_eq!(
        rules, 4,
        "the negative control must reproduce the stranded rows"
    );
}

/// The neutral truncating path, as a control: no reflow, so the rows stay where the app
/// left them and its walk back up lands where it meant to.
#[test]
fn a_truncating_resize_leaves_the_child_s_arithmetic_intact() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    vt.vt_write(b"\x1b[?7h");
    draw_box(&mut vt, 74);
    vt.resize(24, 55).expect("resize");
    child_winch_redraw(&mut vt, 2, 55);
    let text = vt.screen_text().expect("text");
    println!("--- truncating resize, child redraws ---\n{text}");
    let rules = text.lines().filter(|l| l.starts_with('─')).count();
    assert_eq!(rules, 2, "expected exactly the two rules the child drew");
}

#[test]
fn content_resize_preserves_the_childs_row_count_through_a_drag() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    draw_box(&mut vt, 74);
    for cols in [63, 55, 62, 72, 74] {
        vt.resize_for_content(24, cols).expect("resize");
        child_winch_redraw(&mut vt, 2, usize::from(cols));
        let text = vt.screen_text().expect("text");
        assert_eq!(
            text.lines().filter(|line| line.starts_with('─')).count(),
            2,
            "at {cols}: {text}"
        );
        assert_eq!(
            text.lines().filter(|line| line.starts_with('❯')).count(),
            1,
            "at {cols}: {text}"
        );
    }
}

#[test]
fn content_resize_handles_split_control_sequences() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    for byte in format!(
        "\x1b[1;1H{}\x1b[2;1H❯ \x1b[3;1H{}",
        "─".repeat(74),
        "─".repeat(74)
    )
    .as_bytes()
    {
        vt.vt_write(&[*byte]);
    }
    vt.resize_for_content(24, 55).expect("resize");
    child_winch_redraw(&mut vt, 2, 55);
    assert_eq!(
        vt.screen_text()
            .expect("text")
            .lines()
            .filter(|line| line.starts_with('─'))
            .count(),
        2
    );
}

#[test]
fn flowing_output_still_rejoins_on_widening() {
    let mut vt = VtTerminal::new(12, 20).expect("new");
    vt.vt_write(b"build-output-with-a-long-tail");
    vt.resize_for_content(12, 40).expect("resize");
    assert!(vt
        .screen_text()
        .expect("text")
        .contains("build-output-with-a-long-tail"));
}

#[test]
fn historical_output_above_a_canvas_survives_narrowing_and_rejoins() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    let history = "history-".repeat(9);
    vt.vt_write(b"\x1b[H");
    vt.vt_write(format!("{history}\r\n{history}\r\n").as_bytes());
    vt.vt_write(
        format!(
            "\x1b[3;1H{}\x1b[4;1H❯ \x1b[5;1H{}",
            "─".repeat(74),
            "─".repeat(74)
        )
        .as_bytes(),
    );
    vt.resize_for_content(24, 55).expect("narrow");
    child_winch_redraw(&mut vt, 2, 55);
    vt.resize_for_content(24, 74).expect("widen");
    child_winch_redraw(&mut vt, 2, 74);
    let text = vt.screen_text().expect("text");
    assert_eq!(text.matches(&history).count(), 2, "{text}");
    assert_eq!(
        text.lines().filter(|line| line.starts_with('─')).count(),
        2,
        "{text}"
    );
}

#[test]
fn a_new_command_leaves_canvas_mode() {
    let mut vt = VtTerminal::new(24, 20).expect("new");
    vt.vt_write(b"\x1b[Hprompt\x1b]133;C\x07\r\nbuild-output-with-a-long-tail");
    vt.resize_for_content(24, 40).expect("resize");
    assert!(vt
        .screen_text()
        .expect("text")
        .contains("build-output-with-a-long-tail"));
}

#[test]
fn an_alternate_canvas_does_not_truncate_primary_history() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    let history = "history-".repeat(9);
    vt.vt_write(history.as_bytes());
    vt.vt_write(b"\x1b[?1049h");
    draw_box(&mut vt, 74);
    vt.resize_for_content(24, 55).expect("narrow");
    child_winch_redraw(&mut vt, 2, 55);
    assert_eq!(
        vt.screen_text()
            .expect("text")
            .lines()
            .filter(|line| line.starts_with('─'))
            .count(),
        2
    );
    vt.resize_for_content(24, 74).expect("widen");
    vt.vt_write(b"\x1b[?1049l");
    assert!(vt.screen_text().expect("text").contains(&history));
}

#[test]
fn canvas_resize_preserves_background_and_saved_cursor() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    vt.vt_write(b"\x1b[6;4H\x1b7");
    draw_box(&mut vt, 74);
    vt.vt_write(b"\x1b[44m");
    vt.resize_for_content(24, 55).expect("narrow");
    child_winch_redraw(&mut vt, 2, 55);
    assert_eq!(
        vt.screen_text()
            .expect("text")
            .lines()
            .filter(|line| line.starts_with('─'))
            .count(),
        2
    );
    assert_eq!(
        vt.snapshot().expect("background").cells[0].background,
        termiod_vt::Color::Palette(4)
    );
    vt.vt_write(b"\x1b8X");
    let snapshot = vt.snapshot().expect("snapshot");
    assert_eq!(
        snapshot
            .cells
            .iter()
            .position(|cell| cell.codepoint == u32::from('X'))
            .map(|index| index / 55),
        Some(5)
    );
}

#[test]
fn scrollback_above_a_canvas_reflows_without_losing_tails() {
    let mut vt = VtTerminal::new(6, 74).expect("new");
    let history = "history-".repeat(9);
    for _ in 0..12 {
        vt.vt_write(format!("{history}\r\n").as_bytes());
    }
    let before = vt.scrollback(100).expect("history");
    draw_box(&mut vt, 74);
    for cols in [55, 74] {
        vt.resize_for_content(6, cols).expect("resize");
        child_winch_redraw(&mut vt, 2, usize::from(cols));
    }
    let after = vt.scrollback(100).expect("history");
    let text_rows = |history: termiod_vt::Scrollback| -> Vec<String> {
        history
            .rows
            .iter()
            .map(|row| {
                row.iter()
                    .map(|cell| char::from_u32(cell.codepoint).unwrap_or(' '))
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    };
    let expected = text_rows(before)
        .iter()
        .filter(|row| row.starts_with(&history))
        .count();
    let retained = text_rows(after)
        .iter()
        .filter(|row| row.starts_with(&history))
        .count()
        + vt.screen_text().expect("screen").matches(&history).count();
    assert_eq!(
        retained, expected,
        "history may enter the viewport, but must not be erased"
    );
}

#[test]
fn control_strings_do_not_claim_a_flowing_screen() {
    let mut vt = VtTerminal::new(12, 74).expect("new");
    vt.vt_write(b"\x1b]0;not-a-cursor-command:\x1b[H\x07");
    let text = "history-".repeat(9);
    vt.vt_write(text.as_bytes());
    vt.resize_for_content(12, 55).expect("narrow");
    vt.resize_for_content(12, 74).expect("widen");
    assert!(vt.screen_text().expect("text").contains(&text));
}

#[test]
fn content_resize_waits_for_the_childs_final_redraw_without_stranding_rows() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    draw_box(&mut vt, 74);
    for cols in [63, 55, 62, 72, 74] {
        vt.resize_for_content(24, cols).expect("resize");
    }
    child_winch_redraw(&mut vt, 2, 74);
    let text = vt.screen_text().expect("text");
    assert_eq!(
        text.lines().filter(|line| line.starts_with('─')).count(),
        2,
        "{text}"
    );
}

#[test]
fn resize_preserves_an_incomplete_cursor_sequence_and_its_snapshot_suffix() {
    let mut vt = VtTerminal::new(24, 74).expect("new");
    draw_box(&mut vt, 74);
    vt.vt_write(b"\x1b[");
    vt.resize_for_content(24, 55).expect("resize");
    let mut client = VtTerminal::new(24, 55).expect("client");
    client.vt_write(&vt.format_vt().expect("snapshot"));
    let suffix = format!("2A\r\x1b[J{}\r\n❯ \r\n{}", "─".repeat(55), "─".repeat(55));
    vt.vt_write(suffix.as_bytes());
    client.vt_write(suffix.as_bytes());
    let text = vt.screen_text().expect("text");
    assert_eq!(
        text.lines().filter(|line| line.starts_with('─')).count(),
        2,
        "{text}"
    );
    assert_eq!(
        vt.snapshot().expect("host").cells,
        client.snapshot().expect("client").cells
    );
}

#[test]
fn resize_preserves_split_utf8_and_osc_payloads() {
    for (prefix, suffix) in [
        (b"\xe2\x94".as_slice(), b"\x80".as_slice()),
        (b"\x1b(".as_slice(), b"0q".as_slice()),
        (b"\x1b]0;title".as_slice(), b"\x07X".as_slice()),
    ] {
        let mut vt = VtTerminal::new(24, 74).expect("new");
        draw_box(&mut vt, 74);
        vt.vt_write(prefix);
        vt.resize_for_content(24, 55).expect("resize");
        let mut client = VtTerminal::new(24, 55).expect("client");
        client.vt_write(&vt.format_vt().expect("snapshot"));
        vt.vt_write(suffix);
        client.vt_write(suffix);
        assert_eq!(
            vt.snapshot().expect("host").cells,
            client.snapshot().expect("client").cells
        );
    }
}

#[test]
fn clearing_and_homing_before_a_build_log_does_not_disable_reflow() {
    let mut vt = VtTerminal::new(12, 74).expect("new");
    vt.vt_write(b"\x1b[H\x1b[2J");
    let text = "history-".repeat(9);
    vt.vt_write(text.as_bytes());
    vt.resize_for_content(12, 55).expect("narrow");
    vt.resize_for_content(12, 74).expect("widen");
    assert!(vt.screen_text().expect("text").contains(&text));
}
