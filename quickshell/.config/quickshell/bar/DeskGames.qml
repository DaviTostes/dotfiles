import QtQuick
import "../hyprconf"

// The arcade games (2048 / minesweeper / dice) as a plain content block, hosted
// by the desktop dock window (bar/TypeTest.qml) — the old arcade bar pill is
// gone. `tab` selects the game: 0 = 2048, 1 = mines, 2 = dice.
Item {
  id: root

  property int tab: 0
  // whether the window hosting this block is on screen (gates the snake timer)
  property bool active: true

  implicitWidth: 300
  implicitHeight: root.tab === 0 ? game2048.implicitHeight
                : root.tab === 1 ? mines.implicitHeight
                : root.tab === 2 ? dice.implicitHeight
                : snakeGame.implicitHeight

  // =======================================================================
  //  2048
  // =======================================================================
  property var board: []
  property int score2048: 0
  property bool won2048: false
  property bool over2048: false

  // value → vivid swatch from the shared palette (2 → red … 256 → pink,
  // then clamped); empty cells are a flat surface. Keeps the rule that
  // components never hardcode colors.
  function tileColor(v) {
    if (!(v > 0)) return Theme.surface;
    let i = Math.round(Math.log2(v)) - 1;
    i = Math.max(0, Math.min(Theme.tagColors.length - 1, i));
    return Theme.tagColors[i];
  }

  function emptyCells2048(b) {
    const r = [];
    for (let i = 0; i < 16; i++) if (b[i] === 0) r.push(i);
    return r;
  }

  function addRandom2048() {
    const b = root.board.slice();
    const empt = root.emptyCells2048(b);
    if (empt.length === 0) return;
    b[empt[Math.floor(Math.random() * empt.length)]] =
        Math.random() < 0.9 ? 2 : 4;
    root.board = b;
  }

  function reset2048() {
    root.board = new Array(16).fill(0);
    root.score2048 = 0;
    root.won2048 = false;
    root.over2048 = false;
    root.addRandom2048();
    root.addRandom2048();
  }

  // dir: 0 up, 1 right, 2 down, 3 left
  function move2048(dir) {
    if (root.over2048) return;
    const b = root.board.slice();
    let gained = 0;
    let moved = false;

    for (let line = 0; line < 4; line++) {
      const idxs = [];
      for (let k = 0; k < 4; k++) {
        let x, y;
        if (dir === 0) { x = line; y = k; }
        else if (dir === 2) { x = line; y = 3 - k; }
        else if (dir === 3) { x = k; y = line; }
        else { x = 3 - k; y = line; }
        idxs.push(y * 4 + x);
      }

      const vals = idxs.map(i => b[i]).filter(v => v !== 0);
      const out = [];
      for (let i = 0; i < vals.length; i++) {
        if (i + 1 < vals.length && vals[i] === vals[i + 1]) {
          const merged = vals[i] * 2;
          out.push(merged);
          gained += merged;
          if (merged === 2048) root.won2048 = true;
          i++;
        } else out.push(vals[i]);
      }
      while (out.length < 4) out.push(0);

      for (let k = 0; k < 4; k++) {
        if (b[idxs[k]] !== out[k]) moved = true;
        b[idxs[k]] = out[k];
      }
    }

    if (!moved) return;
    root.score2048 += gained;
    root.board = b;
    root.addRandom2048();
    root.checkOver2048();
  }

  function checkOver2048() {
    const b = root.board;
    if (root.emptyCells2048(b).length > 0) { root.over2048 = false; return; }
    for (let y = 0; y < 4; y++)
      for (let x = 0; x < 4; x++) {
        const v = b[y * 4 + x];
        if (x < 3 && b[y * 4 + x + 1] === v) { root.over2048 = false; return; }
        if (y < 3 && b[(y + 1) * 4 + x] === v) { root.over2048 = false; return; }
      }
    root.over2048 = true;
  }

  // =======================================================================
  //  minesweeper
  // =======================================================================
  readonly property int mineN: 9
  readonly property int mineCount: 10
  property var cells: []
  property bool mineFirst: true
  property string mineState: "playing"   // playing | won | lost
  property int flags: 0

  function nb(i) {
    const n = root.mineN;
    const x = i % n, y = Math.floor(i / n);
    const out = [];
    for (let dy = -1; dy <= 1; dy++)
      for (let dx = -1; dx <= 1; dx++) {
        if (dx === 0 && dy === 0) continue;
        const nx = x + dx, ny = y + dy;
        if (nx >= 0 && nx < n && ny >= 0 && ny < n) out.push(ny * n + nx);
      }
    return out;
  }

  function newMines() {
    const arr = [];
    for (let i = 0; i < root.mineN * root.mineN; i++)
      arr.push({ mine: false, revealed: false, flagged: false, adj: 0 });
    root.cells = arr;
    root.mineFirst = true;
    root.mineState = "playing";
    root.flags = 0;
  }

  // QML compares a `var` property by reference, so handing back the SAME cell
  // objects after mutating them leaves every delegate binding stale (the board
  // looks frozen). Every write therefore publishes a fresh array of fresh
  // objects, so `root.cells[index]` really changes and the tiles repaint.
  function cloneCells(arr) {
    const out = [];
    for (const c of arr)
      out.push({ mine: c.mine, revealed: c.revealed, flagged: c.flagged, adj: c.adj });
    return out;
  }

  function placeMines(safe) {
    const n = root.mineN;
    const total = n * n;
    const arr = root.cells.slice();

    const banned = new Set([safe, ...root.nb(safe)]);
    const pool = [];
    for (let i = 0; i < total; i++) if (!banned.has(i)) pool.push(i);
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const t = pool[i]; pool[i] = pool[j]; pool[j] = t;
    }
    for (let k = 0; k < root.mineCount && k < pool.length; k++)
      arr[pool[k]].mine = true;

    for (let i = 0; i < total; i++) {
      if (arr[i].mine) { arr[i].adj = 0; continue; }
      let c = 0;
      for (const j of root.nb(i)) if (arr[j].mine) c++;
      arr[i].adj = c;
    }

    root.cells = root.cloneCells(arr);
    root.mineFirst = false;
  }

  function revealCell(i) {
    if (root.mineState !== "playing") return;
    if (root.mineFirst) root.placeMines(i);

    const arr = root.cells.slice();
    const c = arr[i];
    if (!c || c.revealed || c.flagged) return;

    if (c.mine) {
      for (const cc of arr) if (cc.mine) cc.revealed = true;
      root.cells = root.cloneCells(arr);
      root.mineState = "lost";
      return;
    }

    const stack = [i];
    while (stack.length) {
      const k = stack.pop();
      const cc = arr[k];
      if (cc.revealed || cc.flagged) continue;
      cc.revealed = true;
      if (cc.adj === 0)
        for (const j of root.nb(k))
          if (!arr[j].revealed && !arr[j].mine) stack.push(j);
    }
    root.cells = root.cloneCells(arr);
    root.checkMines();
  }

  function flagCell(i) {
    if (root.mineState !== "playing") return;
    const arr = root.cells.slice();
    const c = arr[i];
    if (!c || c.revealed) return;
    c.flagged = !c.flagged;
    root.flags += c.flagged ? 1 : -1;
    root.cells = root.cloneCells(arr);
  }

  function checkMines() {
    let hidden = 0;
    for (const c of root.cells)
      if (!c.mine && !c.revealed) hidden++;
    if (hidden === 0) root.mineState = "won";
  }

  // =======================================================================
  //  dice / coin
  // =======================================================================
  property string dieKind: "d6"     // d6 | d20 | coin
  property int dieValue: 6
  property bool rolling: false
  property var rolls: []
  property int rollTick: 0

  function randomFace() {
    if (root.dieKind === "coin") return Math.random() < 0.5 ? 0 : 1;
    const sides = root.dieKind === "d20" ? 20 : 6;
    return 1 + Math.floor(Math.random() * sides);
  }

  function faceLabel(v) {
    if (root.dieKind === "coin") return v === 0 ? "H" : "T";
    return String(v);
  }

  function rollDice() {
    if (root.rolling) return;
    root.rolling = true;
    root.rollTick = 0;
    rollTimer.restart();
  }

  function pushRoll() {
    const list = root.rolls.slice();
    list.unshift({ kind: root.dieKind, value: root.dieValue });
    root.rolls = list.slice(0, 7);
  }

  Timer {
    id: rollTimer
    interval: 70
    repeat: true
    onTriggered: {
      root.dieValue = root.randomFace();
      root.rollTick++;
      if (root.rollTick >= 12) {
        rollTimer.stop();
        root.rolling = false;
        root.pushRoll();
      }
    }
  }

  // =======================================================================
  //  snake
  // =======================================================================
  readonly property int snakeN: 16
  property var snake: []          // head first: [{x, y}, ...]
  property int snakeDX: 1
  property int snakeDY: 0
  property int snakeFoodX: -1
  property int snakeFoodY: -1
  property int snakeScore: 0
  property bool snakeOver: false

  function newSnake() {
    const cy = Math.floor(root.snakeN / 2);
    root.snake = [ { x: 4, y: cy }, { x: 3, y: cy }, { x: 2, y: cy } ];
    root.snakeDX = 1;
    root.snakeDY = 0;
    root.snakeScore = 0;
    root.snakeOver = false;
    root.placeSnakeFood();
  }

  function placeSnakeFood() {
    const n = root.snakeN;
    const free = [];
    for (let y = 0; y < n; y++)
      for (let x = 0; x < n; x++)
        if (!root.snake.some(s => s.x === x && s.y === y)) free.push({ x: x, y: y });
    if (free.length === 0) { root.snakeFoodX = -1; root.snakeFoodY = -1; return; }
    const f = free[Math.floor(Math.random() * free.length)];
    root.snakeFoodX = f.x;
    root.snakeFoodY = f.y;
  }

  function snakeIndexAt(x, y) {
    const s = root.snake;
    for (let i = 0; i < s.length; i++) if (s[i].x === x && s[i].y === y) return i;
    return -1;
  }

  function snakeTurn(dx, dy) {
    if (dx === root.snakeDX && dy === root.snakeDY) return;
    if (dx === -root.snakeDX && dy === -root.snakeDY) return;   // no reverse
    root.snakeDX = dx;
    root.snakeDY = dy;
  }

  function snakeStep() {
    if (root.snakeOver) return;
    const n = root.snakeN;
    const s = root.snake.slice();
    const head = s[0];
    const nx = head.x + root.snakeDX;
    const ny = head.y + root.snakeDY;
    if (nx < 0 || nx >= n || ny < 0 || ny >= n) { root.snakeOver = true; return; }

    const ate = (nx === root.snakeFoodX && ny === root.snakeFoodY);
    // the tail moves away this step unless we eat, so it does not collide
    const limit = ate ? s.length : s.length - 1;
    for (let i = 0; i < limit; i++)
      if (s[i].x === nx && s[i].y === ny) { root.snakeOver = true; return; }

    s.unshift({ x: nx, y: ny });
    if (ate) { root.snakeScore += 1; root.placeSnakeFood(); }
    else s.pop();
    root.snake = s;
  }

  Timer {
    id: snakeTimer
    interval: 140
    repeat: true
    running: root.active && root.tab === 3 && !root.snakeOver
    onTriggered: root.snakeStep()
  }

  Component.onCompleted: {
    root.reset2048();
    root.newMines();
    root.newSnake();
  }

  // contextual "new" for the current game (2048 / mines / snake)
  function resetCurrent() {
    if (root.tab === 0) root.reset2048();
    else if (root.tab === 1) root.newMines();
    else if (root.tab === 3) root.newSnake();
  }

  // keyboard: arrows + WASD drive 2048 and snake, R restarts
  function handleKey(event) {
    const up = event.key === Qt.Key_Up || event.key === Qt.Key_W;
    const right = event.key === Qt.Key_Right || event.key === Qt.Key_D;
    const down = event.key === Qt.Key_Down || event.key === Qt.Key_S;
    const left = event.key === Qt.Key_Left || event.key === Qt.Key_A;

    if (root.tab === 0) {
      let dir = -1;
      if (up) dir = 0;
      else if (right) dir = 1;
      else if (down) dir = 2;
      else if (left) dir = 3;
      else if (event.key === Qt.Key_R) { root.reset2048(); event.accepted = true; return; }
      else return;
      root.move2048(dir);
      event.accepted = true;
    } else if (root.tab === 3) {
      if (up) root.snakeTurn(0, -1);
      else if (right) root.snakeTurn(1, 0);
      else if (down) root.snakeTurn(0, 1);
      else if (left) root.snakeTurn(-1, 0);
      else if (event.key === Qt.Key_R) root.newSnake();
      else return;
      event.accepted = true;
    }
  }

  // =======================================================================
  //  2048 board
  // =======================================================================
  Item {
    id: game2048
    visible: root.tab === 0
    width: parent.width
    implicitHeight: status2048.height + 8 + board.implicitHeight

    Item {
      id: status2048
      width: parent.width
      height: 16

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
        text: "score"
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: 40
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 12
        color: Theme.accent
        text: root.score2048
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.pixelSize: 10
        color: root.over2048 ? Theme.err : root.won2048 ? Theme.live : Theme.muted
        text: root.over2048 ? "game over — R / new"
            : root.won2048 ? "2048! keep going" : "swipe or arrows"
      }
    }

    Grid {
      id: board
      anchors.top: status2048.bottom
      anchors.topMargin: 8
      anchors.horizontalCenter: parent.horizontalCenter
      columns: 4
      spacing: 6

      Repeater {
        model: 16

        delegate: Rectangle {
          id: tile

          required property int index
          readonly property int val: root.board[index] > 0 ? root.board[index] : 0

          width: 64
          height: 64
          radius: 6
          color: root.tileColor(tile.val)
          Behavior on color { ColorAnimation { duration: 150 } }

          SequentialAnimation on scale {
            id: pop
            running: false
            NumberAnimation { from: 0.7; to: 1.0; duration: 140; easing.type: Easing.OutCubic }
          }
          onValChanged: if (tile.val !== 0) pop.restart()

          Text {
            anchors.centerIn: parent
            visible: tile.val !== 0
            text: tile.val
            font.family: Theme.font
            font.bold: true
            font.pixelSize: tile.val > 999 ? 15 : tile.val > 99 ? 18 : 20
            color: Theme.deep
          }
        }
      }
    }

    MouseArea {
      anchors.fill: board
      property real sx: 0
      property real sy: 0
      onPressed: mouse => { sx = mouse.x; sy = mouse.y; }
      onReleased: mouse => {
        const dx = mouse.x - sx;
        const dy = mouse.y - sy;
        if (Math.max(Math.abs(dx), Math.abs(dy)) < 18) return;
        if (Math.abs(dx) > Math.abs(dy)) root.move2048(dx > 0 ? 1 : 3);
        else root.move2048(dy > 0 ? 2 : 0);
      }
    }
  }

  // =======================================================================
  //  minesweeper
  // =======================================================================
  Item {
    id: mines
    visible: root.tab === 1
    width: parent.width
    implicitHeight: statusMines.height + 8 + mineGrid.implicitHeight

    Item {
      id: statusMines
      width: parent.width
      height: 16

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
        text: "mines"
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: 44
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 12
        color: Theme.accent
        text: Math.max(0, root.mineCount - root.flags)
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.pixelSize: 10
        color: root.mineState === "lost" ? Theme.err
             : root.mineState === "won" ? Theme.live : Theme.muted
        text: root.mineState === "lost" ? "boom — new"
            : root.mineState === "won" ? "cleared!" : "click · right-click flags"
      }
    }

    Grid {
      id: mineGrid
      anchors.top: statusMines.bottom
      anchors.topMargin: 8
      anchors.horizontalCenter: parent.horizontalCenter
      columns: root.mineN
      spacing: 3

      Repeater {
        model: root.mineN * root.mineN

        delegate: Rectangle {
          id: cell

          required property int index
          readonly property var c: root.cells[index] || { mine: false, revealed: false, flagged: false, adj: 0 }

          width: 28
          height: 28
          radius: 4
          color: cell.c.revealed
              ? (cell.c.mine ? Theme.err : Theme.bg)
              : (cellMa.containsMouse ? Theme.hover : Theme.surface)
          border.color: Theme.border
          border.width: cell.c.revealed ? 0 : 1
          Behavior on color { ColorAnimation { duration: 120 } }

          Text {
            anchors.centerIn: parent
            font.family: Theme.font
            font.bold: true
            font.pixelSize: 13
            text: cell.c.revealed
                ? (cell.c.mine ? "\uf1e2" : (cell.c.adj > 0 ? cell.c.adj : ""))
                : (cell.c.flagged ? "\uf024" : "")
            color: cell.c.mine && cell.c.revealed ? Theme.deep
                 : cell.c.flagged ? Theme.err
                 : Theme.tagColors[(Math.max(1, cell.c.adj) - 1) % Theme.tagColors.length]
          }

          MouseArea {
            id: cellMa
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: mouse => {
              if (mouse.button === Qt.RightButton) root.flagCell(cell.index);
              else root.revealCell(cell.index);
            }
          }
        }
      }
    }
  }

  // =======================================================================
  //  dice / coin
  // =======================================================================
  Item {
    id: dice
    visible: root.tab === 2
    width: parent.width
    implicitHeight: diceCol.implicitHeight

    Column {
      id: diceCol
      width: parent.width
      spacing: 10

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 6

        Repeater {
          model: [
            { label: "d6", kind: "d6" },
            { label: "d20", kind: "d20" },
            { label: "coin", kind: "coin" }
          ]

          delegate: Rectangle {
            id: kindBtn

            required property var modelData
            readonly property bool sel: root.dieKind === kindBtn.modelData.kind

            width: kindText.implicitWidth + 22
            height: 24
            radius: 6
            color: kindBtn.sel ? Theme.accent
                 : kindMa.containsMouse ? Theme.hover : Theme.surface
            Behavior on color { ColorAnimation { duration: 200 } }

            Text {
              id: kindText
              anchors.centerIn: parent
              font.family: Theme.font
              font.pixelSize: 11
              font.bold: kindBtn.sel
              color: kindBtn.sel ? Theme.deep : Theme.text
              text: kindBtn.modelData.label
            }

            MouseArea {
              id: kindMa
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.dieKind = kindBtn.modelData.kind;
                root.dieValue = root.randomFace();
              }
            }
          }
        }
      }

      Rectangle {
        id: face

        anchors.horizontalCenter: parent.horizontalCenter
        width: 96
        height: 96
        radius: 12
        color: Theme.surface
        border.color: root.rolling ? Theme.accent : Theme.border
        border.width: 2
        Behavior on border.color { ColorAnimation { duration: 150 } }

        Text {
          anchors.centerIn: parent
          font.family: Theme.font
          font.bold: true
          font.pixelSize: root.dieKind === "coin" ? 40 : 44
          color: root.rolling ? Theme.accent2 : Theme.accent
          text: root.faceLabel(root.dieValue)
          Behavior on color { ColorAnimation { duration: 150 } }
        }
      }

      Rectangle {
        id: rollBtn

        anchors.horizontalCenter: parent.horizontalCenter
        width: 140
        height: 28
        radius: 6
        color: rollMa.containsMouse && !root.rolling ? Theme.accent2 : Theme.accent
        Behavior on color { ColorAnimation { duration: 200 } }
        opacity: root.rolling ? 0.6 : 1

        Text {
          anchors.centerIn: parent
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 12
          color: Theme.deep
          text: root.rolling ? "rolling…" : "roll"
        }

        MouseArea {
          id: rollMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.rollDice()
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 4
        visible: root.rolls.length > 0

        Repeater {
          model: root.rolls

          delegate: Rectangle {
            required property var modelData

            width: 28
            height: 20
            radius: 5
            color: Theme.bg
            border.color: Theme.border
            border.width: 1

            Text {
              anchors.centerIn: parent
              font.family: Theme.font
              font.pixelSize: 10
              color: Theme.muted
              text: modelData.kind === "coin"
                  ? (modelData.value === 0 ? "H" : "T")
                  : modelData.value
            }
          }
        }
      }
    }
  }

  // =======================================================================
  //  snake board
  // =======================================================================
  Item {
    id: snakeGame
    visible: root.tab === 3
    width: parent.width
    implicitHeight: snakeStatus.height + 8 + snakeBoard.implicitHeight

    Item {
      id: snakeStatus
      width: parent.width
      height: 16

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.pixelSize: 11
        color: Theme.muted
        text: "score"
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: 40
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.bold: true
        font.pixelSize: 12
        color: Theme.accent
        text: root.snakeScore
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.font
        font.pixelSize: 10
        color: root.snakeOver ? Theme.err : Theme.muted
        text: root.snakeOver ? "game over — R / new" : "arrows or WASD"
      }
    }

    Grid {
      id: snakeBoard
      anchors.top: snakeStatus.bottom
      anchors.topMargin: 8
      anchors.horizontalCenter: parent.horizontalCenter
      columns: root.snakeN
      spacing: 1

      Repeater {
        model: root.snakeN * root.snakeN

        delegate: Rectangle {
          required property int index

          readonly property int cx: index % root.snakeN
          readonly property int cy: Math.floor(index / root.snakeN)
          readonly property int si: root.snakeIndexAt(cx, cy)
          readonly property bool food: cx === root.snakeFoodX && cy === root.snakeFoodY

          width: 16
          height: 16
          radius: 3
          color: food ? Theme.err
               : si === 0 ? Theme.accent
               : si > 0 ? Theme.accent2
               : Theme.surface
          Behavior on color { ColorAnimation { duration: 90 } }
        }
      }
    }

    // swipe the board to steer (declared after the grid so it sits on top)
    MouseArea {
      anchors.fill: snakeBoard
      property real sx: 0
      property real sy: 0
      onPressed: mouse => { sx = mouse.x; sy = mouse.y; }
      onReleased: mouse => {
        const dx = mouse.x - sx;
        const dy = mouse.y - sy;
        if (Math.max(Math.abs(dx), Math.abs(dy)) < 16) return;
        if (Math.abs(dx) > Math.abs(dy)) root.snakeTurn(dx > 0 ? 1 : -1, 0);
        else root.snakeTurn(0, dy > 0 ? 1 : -1);
      }
    }
  }
}
