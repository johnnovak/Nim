import endians
import strformat

proc newIOError(msg: string): ref IOError =
  new(result)
  result.msg = msg


when not defined(js):
  type
    StreamSeekPos = enum
      sspSet, sspCur, sspEnd

  func toFileSeekPos(s: StreamSeekPos): FileSeekPos =
    case s
    of sspSet: fspSet
    of sspCur: fspCur
    of sspEnd: fspEnd

  # {{{ File stream

  type
    FileStream* = ref object
      f: File
      filename: string
      endian: Endianness

  using fs: FileStream

  const
    ReadChunkSize = 512
    WriteBufSize = 512

  proc newFileStream*(f: File, endian: Endianness): FileStream =
    new(result)
    result.f = f
    result.endian = endian

  proc newFileStream*(filename: string, endian: Endianness,
                      mode: FileMode = fmRead,
                      bufSize: int = -1): FileStream =
    var f: File
    if open(f, filename, mode, bufSize):
      result = newFileStream(f, endian)
      result.filename = filename

  proc openFileStream*(filename: string, endian: Endianness,
                       mode: FileMode = fmRead,
                       bufSize: int = -1): FileStream =
    var f: File
    if open(f, filename, mode, bufSize):
      result = newFileStream(f, endian)
      result.filename = filename
    else:
      raise newIOError(fmt"cannot open file '{filename}' using mode {mode}")

  # TODO check closed?
  proc close*(fs) =
    if fs == nil:
      raise newIOError(
        "stream has already been closed or has not been properly initialised")
    if fs.f != nil: close(fs.f)
    fs.f = nil

  proc checkStreamOpen(fs) =
    if fs == nil:
      raise newIOError(
        "stream has been closed or has not been properly initialised")

  proc flush*(fs) =
    fs.checkStreamOpen()
    flushFile(fs.f)

  proc atEnd*(fs): bool =
    fs.checkStreamOpen()
    endOfFile(fs.f)

  proc filename*(fs): string = fs.filename

  proc endian*(fs): Endianness = fs.endian

  proc `endian=`*(fs; endian: Endianness) = fs.endian = endian

  proc getPosition*(fs): int64 =
    fs.checkStreamOpen()
    getFilePos(fs.f).int64

  proc setPosition*(fs; pos: int64, relativeTo: StreamSeekPos = sspSet) =
    fs.checkStreamOpen()
    setFilePos(fs.f, pos, toFileSeekPos(relativeTo))

  proc raiseReadError(fs) =
    raise newIOError(fmt"cannot read from stream, filename: '{fs.filename}'")

  proc readAndSwap[T: SomeNumber](fs; buf: var openArray[T],
                                  startIndex, numValues: Natural) =
    var
      valuesLeft = numValues
      bufIndex = startIndex

    while valuesLeft > 0:
      let
        valuesToRead = min(valuesLeft, ReadChunkSize)
        bytesToRead = valuesToRead * sizeof(T)
        bytesRead = readBuffer(fs.f, buf[bufIndex].addr, bytesToRead)
        valuesRead = valuesToRead

      if bytesRead != bytesToRead:
        fs.raiseReadError()
      dec(valuesLeft, valuesRead)

      for i in bufIndex..<bufIndex + valuesRead:
        buf[i] = swapEndian(buf[i])
      inc(bufIndex, valuesRead)


  proc read*[T: SomeNumber](fs; buf: var openArray[T],
                            startIndex, numValues: Natural) =
    fs.checkStreamOpen()
    if system.cpuEndian == fs.endian:
      assert startIndex + numValues <= buf.len
      let
        bytesToRead = numValues * sizeof(T)
        bytesRead = readBuffer(fs.f, buf[startIndex].addr, bytesToRead)
      if bytesRead != bytesToRead:
        fs.raiseReadError()
    else:
      fs.readAndSwap(buf, startIndex, numValues)

  proc read*(fs; T: typedesc[SomeNumber]): T =
    var buf {.noinit.}: array[1, T]
    fs.read(buf, 0, 1)
    result = buf[0]

  proc readStr*(fs; length: Natural): string =
    result = newString(length)
    fs.read(toOpenArrayByte(result, 0, length-1), 0, length)

  proc readChar*(fs): char =
    result = cast[char](fs.read(byte))

  proc readBool*(fs): bool =
    result = fs.read(byte) != 0


  template doPeekFileStream(fs; body: untyped): untyped =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    body

  proc peek*(fs; T: typedesc[SomeNumber]): T =
    doPeekFileStream(fs): fs.read(T)

  proc peek*[T: SomeNumber](fs; buf: var openArray[T],
                            startIndex, numValues: Natural) =
    doPeekFileStream(fs): fs.read(buf, startIndex, numValues)

  proc peekStr*(fs; length: Natural): string =
    doPeekFileStream(fs): fs.readStr(length)

  proc peekChar*(fs): char =
    doPeekFileStream(fs): fs.readChar()

  proc peekBool*(fs): bool =
    doPeekFileStream(fs): fs.readBool()


  proc raiseWriteError(fs) =
    raise newIOError(fmt"cannot write to stream, filename: '{fs.filename}'")

  proc swapAndWrite[T: SomeNumber](fs; buf: openArray[T],
                                   startIndex, numValues: Natural) =
    var
      writeBuf {.noinit.}: array[WriteBufSize, T]
      valuesLeft = numValues
      bufIndex = startIndex

    while valuesLeft > 0:
      let valuesToWrite = min(valuesLeft, writeBuf.len)
      for i in 0..<valuesToWrite:
        writeBuf[i] = swapEndian(buf[bufIndex])
        inc(bufIndex)

      let
        bytesToWrite = valuesToWrite * sizeof(T)
        bytesWritten = writeBuffer(fs.f, writeBuf[0].addr, bytesToWrite)

      if bytesWritten != bytesToWrite:
        raiseWriteError(fs)
      dec(valuesLeft, valuesToWrite)


  proc write*[T: SomeNumber](fs; buf: openArray[T],
                             startIndex, numValues: Natural) =
    fs.checkStreamOpen()
    if system.cpuEndian == fs.endian:
      assert startIndex + numValues <= buf.len
      let
        bytesToWrite = numValues * sizeof(T)
        bytesWritten = writeBuffer(fs.f, buf[startIndex].unsafeAddr,
                                   bytesToWrite)
      if bytesWritten != bytesToWrite:
        raiseWriteError(fs)
    else:
      fs.swapAndWrite(buf, startIndex, numValues)

  proc write*[T: SomeNumber](fs; value: T) =
    var buf {.noinit.}: array[1, T]
    buf[0] = value
    fs.write(buf, 0, 1)

  proc writeStr*(fs; s: string) =
    fs.write(toOpenArrayByte(s, 0, s.len-1), 0, s.len)

  proc writeChar*(fs; ch: char) =
    fs.write(cast[byte](ch))

  proc writeBool*(fs; b: bool) =
    fs.write(cast[byte](b))

  # }}}
  # {{{ Byte stream

  type
    ByteStream* = ref object
      buf: seq[byte]
      pos: Natural
      endian: Endianness
      closed: bool

  using bs: ByteStream

  proc newByteStream*(buf: seq[byte], endian: Endianness): ByteStream =
    new(result)
    result.buf = buf
    result.endian = endian

  proc newByteStream*(endian: Endianness, withCap: Natural = 32): ByteStream =
    new(result)
    result.buf = newSeqOfCap[byte](withCap)
    result.endian = endian

  proc close*(bs) = bs.closed = true

  proc checkStreamOpen(bs) =
    if bs.closed:
      raise newIOError("stream has been closed")

  proc flush*(bs) = bs.checkStreamOpen()

  proc atEnd*(bs): bool =
    bs.checkStreamOpen()
    bs.pos == bs.buf.high

  proc endian*(bs): Endianness = bs.endian

  proc `endian=`*(bs; endian: Endianness) = bs.endian = endian

  proc getPosition*(bs): int64 =
    bs.checkStreamOpen()
    bs.pos.int64

  proc setPosition*(bs; pos: int64, relativeTo: StreamSeekPos = sspSet) =
    bs.checkStreamOpen()
    case relativeTo
    of sspSet: bs.pos = pos
    of sspCur: bs.pos = bs.pos + pos
    of sspEnd: bs.pos = bs.buf.high - pos  # TODO min/max?

  proc raiseReadError(bs) =
    raise newIOError(fmt"cannot read from stream")


  proc readAndSwap[T: SomeNumber](bs; buf: var openArray[T],
                                  startIndex, numValues: Natural) =
    var
      valuesLeft = numValues
      bufIndex = startIndex

    while valuesLeft > 0:
      let
        valuesToRead = min(valuesLeft, ReadChunkSize)
        bytesToRead = valuesToRead * sizeof(T)
        numBytes = min(bytesToRead, bs.buf.len - bs.pos) # TODO negative numbers
      when nimvm:
        for i in 0..<numBytes:
          buf[startIndex + i] = bs.buf[bs.pos + i]
      else:
        copyMem(buf[startIndex].addr, bs.buf[bs.pos].addr, numBytes)
      bs.pos += numBytes  # TODO what does file do if there's failure?
      if numBytes != bytesToRead:
        bs.raiseReadError()
      let valuesRead = valuesToRead
      dec(valuesLeft, valuesRead)

      for i in bufIndex..<bufIndex + valuesRead:
        buf[i] = swapEndian(buf[i])
      inc(bufIndex, valuesRead)


  # TODO merge into a single func
  proc read*[T: SomeNumber](bs; buf: var openArray[T],
                            startIndex, numValues: Natural) =
    bs.checkStreamOpen()
    if numValues == 0: return

    if system.cpuEndian == bs.endian:
      assert startIndex + numValues <= buf.len
      let bytesToRead = numValues * sizeof(T)
      let numBytes = min(bytesToRead, bs.buf.len - bs.pos) # TODO negative numbers
      when nimvm:
        for i in 0..<numBytes:
          buf[startIndex + i] = bs.buf[bs.pos + i]
      else:
        copyMem(buf[startIndex].addr, bs.buf[bs.pos].addr, numBytes)
      bs.pos += numBytes  # TODO what does file do if there's failure?
      if numBytes != bytesToRead:
        bs.raiseReadError()
    else:
      bs.readAndSwap(buf, startIndex, numValues)


  proc read*(bs; T: typedesc[SomeNumber]): T =
    var buf {.noinit.}: array[1, T]
    bs.read(buf, 0, 1)
    result = buf[0]

  proc readStr*(bs; length: Natural): string =
    result = newString(length)
    bs.read(toOpenArrayByte(result, 0, length-1), 0, length)

  proc readChar*(bs): char =
    result = cast[char](bs.read(byte))

  proc readBool*(bs): bool =
    result = bs.read(byte) != 0


  template doPeekByteStream(bs; body: untyped): untyped =
    let pos = bs.getPosition()
    defer: bs.setPosition(pos)
    body

  proc peek*(bs; T: typedesc[SomeNumber]): T =
    doPeekByteStream(bs): bs.read(T)

  proc peek*[T: SomeNumber](bs; buf: var openArray[T],
                            startIndex, numValues: Natural) =
    doPeekByteStream(bs): bs.read(buf, startIndex, numValues)

  proc peekStr*(bs; length: Natural): string =
    doPeekByteStream(bs): bs.readStr(length)

  proc peekChar*(bs): char =
    doPeekByteStream(bs): bs.readChar()

  proc peekBool*(bs): bool =
    doPeekByteStream(bs): bs.readBool()

#[
  proc raiseWriteError(bs) =
    raise newIOError(fmt"cannot write to stream, filename: '{bs.filename}'")

  proc swapAndWrite[T: SomeNumber](bs; buf: openArray[T],
                                   startIndex, numValues: Natural) =
    var
      writeBuf {.noinit.}: array[WriteBufSize, T]
      valuesLeft = numValues
      bufIndex = startIndex

    while valuesLeft > 0:
      let valuesToWrite = min(valuesLeft, writeBuf.len)
      for i in 0..<valuesToWrite:
        writeBuf[i] = swapEndian(buf[bufIndex])
        inc(bufIndex)

      let
        bytesToWrite = valuesToWrite * sizeof(T)
        bytesWritten = writeBuffer(bs.f, writeBuf[0].addr, bytesToWrite)

      if bytesWritten != bytesToWrite:
        raiseWriteError(bs)
      dec(valuesLeft, valuesToWrite)


  proc write*[T: SomeNumber](bs; buf: openArray[T],
                             startIndex, numValues: Natural) =
    bs.checkStreamOpen()
    if system.cpuEndian == bs.endian:
      assert startIndex + numValues <= buf.len
      let
        bytesToWrite = numValues * sizeof(T)
        bytesWritten = writeBuffer(bs.f, buf[startIndex].unsafeAddr,
                                   bytesToWrite)
      if bytesWritten != bytesToWrite:
        raiseWriteError(bs)
    else:
      bs.swapAndWrite(buf, startIndex, numValues)

  proc write*[T: SomeNumber](bs; value: T) =
    var buf {.noinit.}: array[1, T]
    buf[0] = value
    bs.write(buf, 0, 1)

  proc writeStr*(bs; s: string) =
    bs.write(toOpenArrayByte(s, 0, s.len-1), 0, s.len)

  proc writeChar*(bs; ch: char) =
    bs.write(cast[byte](ch))

  proc writeBool*(bs; b: bool) =
    bs.write(cast[byte](b))
]#
  # }}}

when isMainModule:
  const
    TestFileBE = "endians-testdata-BE"
    TestFileLE = "endians-testdata-LE"
    TestFileBigBE = "endians-testdata-big-BE"
    TestFileBigLE = "endians-testdata-big-LE"
    TestFile = "endians-testfile"

  const
    TestFloat64 = 123456789.123456'f64
    TestFloat32 = 1234.1234'f32
    MagicValue64_1 = 0xdeadbeefcafebabe'u64
    MagicValue64_2 = 0xfeedface0d15ea5e'u64
    TestString = "Some girls wander by mistake"
    TestChar = char(42)
    TestBooleans = @[-127'i8, -1'i8, 0'i8, 1'i8, 127'i8]

  # Helpers
  template getAs(T: typedesc[SomeNumber], buf: openArray[byte],
                 startIndex: Natural): T =
    cast[ptr T](buf[startIndex].addr)[]

  # {{{ Test data file creation
  block:
    var outf = open(TestFileBE, fmWrite)
    var buf: array[2, uint64]
    buf[0] = toBE(MagicValue64_1)
    buf[1] = toBE(MagicValue64_2)
    discard writeBuffer(outf, buf[0].addr, 16)

    var f32 = toBE(TestFloat32)
    discard writeBuffer(outf, f32.addr, 4)
    var f64 = toBE(TestFloat64)
    discard writeBuffer(outf, f64.addr, 8)

    var str = TestString
    discard writeBuffer(outf, str[0].unsafeAddr, str.len)
    var ch = TestChar
    discard writeBuffer(outf, ch.unsafeAddr, 1)
    discard writeBytes(outf, TestBooleans, 0, TestBooleans.len)
    close(outf)

  block:
    var outf = open(TestFileLE, fmWrite)
    var buf: array[2, uint64]
    buf[0] = toLE(MagicValue64_1)
    buf[1] = toLE(MagicValue64_2)
    discard writeBuffer(outf, buf[0].addr, 16)

    var f32 = toLE(TestFloat32)
    discard writeBuffer(outf, f32.addr, 4)
    var f64 = toLE(TestFloat64)
    discard writeBuffer(outf, f64.addr, 8)

    var str = TestString
    discard writeBuffer(outf, str[0].unsafeAddr, str.len)
    var ch = TestChar
    discard writeBuffer(outf, ch.unsafeAddr, 1)
    discard writeBytes(outf, TestBooleans, 0, TestBooleans.len)
    close(outf)

  block:
    var outf = open(TestFileBigBE, fmWrite)
    var u64: uint64
    for i in 0..<ReadChunkSize*3:
      u64 = toBE(MagicValue64_1 + i.uint64)
      discard writeBuffer(outf, u64.addr, 8)
    close(outf)

  block:
    var outf = open(TestFileBigLE, fmWrite)
    var u64: uint64
    for i in 0..<ReadChunkSize*3:
      u64 = toLE(MagicValue64_1 + i.uint64)
      discard writeBuffer(outf, u64.addr, 8)
    close(outf)

  # }}}
  # {{{ FileStream read tests
  # -------------------------
  block: # {{{ Big endian

    block: # {{{ read/func
      var fs = newFileStream(TestFileBE, bigEndian)

      assert fs.read(int8)   == 0xde'i8
      assert fs.read(int8)   == 0xad'i8
      fs.setPosition(0)
      assert fs.read(uint8)  == 0xde'u8
      assert fs.read(uint8)  == 0xad'u8
      fs.setPosition(0)
      assert fs.read(int16)  == 0xdead'i16
      assert fs.read(int16)  == 0xbeef'i16
      fs.setPosition(0)
      assert fs.read(uint16) == 0xdead'u16
      assert fs.read(uint16) == 0xbeef'u16
      fs.setPosition(0)
      assert fs.read(int32)  == 0xdeadbeef'i32
      assert fs.read(int32)  == 0xcafebabe'i32
      fs.setPosition(0)
      assert fs.read(uint32) == 0xdeadbeef'u32
      assert fs.read(uint32) == 0xcafebabe'u32
      fs.setPosition(0)
      assert fs.read(int64)  == 0xdeadbeefcafebabe'i64
      assert fs.read(int64)  == 0xfeedface0d15ea5e'i64
      fs.setPosition(0)
      assert fs.read(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.read(uint64) == 0xfeedface0d15ea5e'u64
      fs.setPosition(0)
      assert fs.read(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.read(uint64) == 0xfeedface0d15ea5e'u64

      assert fs.read(float32) == TestFloat32
      assert fs.read(float64) == TestFloat64
      assert fs.getPosition == 28

      assert fs.readStr(TestString.len) == TestString
      assert fs.readChar() == TestChar
      assert fs.readBool() == true
      assert fs.readBool() == true
      assert fs.readBool() == false
      assert fs.readBool() == true
      assert fs.readBool() == true
      fs.close()

    # }}}
    block: # {{{ peek/func
      var fs = newFileStream(TestFileBE, bigEndian)

      assert fs.peek(int8)   == 0xde'i8
      assert fs.peek(int8)   == 0xde'i8
      assert fs.peek(uint8)  == 0xde'u8
      assert fs.peek(uint8)  == 0xde'u8
      assert fs.peek(int16)  == 0xdead'i16
      assert fs.peek(int16)  == 0xdead'i16
      assert fs.peek(uint16) == 0xdead'u16
      assert fs.peek(uint16) == 0xdead'u16
      assert fs.peek(int32)  == 0xdeadbeef'i32
      assert fs.peek(int32)  == 0xdeadbeef'i32
      assert fs.peek(uint32) == 0xdeadbeef'u32
      assert fs.peek(uint32) == 0xdeadbeef'u32
      assert fs.peek(int64)  == 0xdeadbeefcafebabe'i64
      assert fs.peek(int64)  == 0xdeadbeefcafebabe'i64
      assert fs.peek(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.peek(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.getPosition() == 0

      fs.setPosition(16)
      assert fs.peek(float32) == TestFloat32
      fs.setPosition(20)
      assert fs.peek(float64) == TestFloat64
      assert fs.getPosition() == 20

      fs.setPosition(28)
      assert fs.peekStr(TestString.len) == TestString
      fs.setPosition(TestString.len, sspCur)
      assert fs.peekChar() == TestChar; fs.setPosition(1, sspCur)
      assert fs.peekBool() == true;     fs.setPosition(1, sspCur)
      assert fs.peekBool() == true;     fs.setPosition(1, sspCur)
      assert fs.peekBool() == false;    fs.setPosition(1, sspCur)
      assert fs.peekBool() == true;     fs.setPosition(1, sspCur)
      assert fs.peekBool() == true
      fs.close()

    # }}}
    block: # {{{ read/openArray
      var fs = newFileStream(TestFileBE, bigEndian)
      var arr_i8: array[4, int8]

      fs.read(arr_i8, 1, 2)
      assert arr_i8[0] == 0
      assert arr_i8[1] == 0xde'i8
      assert arr_i8[2] == 0xad'i8
      assert arr_i8[3] == 0

      var arr_u8: array[4, uint8]
      fs.setPosition(0)
      fs.read(arr_u8, 1, 2)
      assert arr_u8[0] == 0
      assert arr_u8[1] == 0xde'u8
      assert arr_u8[2] == 0xad'u8
      assert arr_u8[3] == 0

      var arr_i16: array[4, int16]
      fs.setPosition(0)
      fs.read(arr_i16, 1, 2)
      assert arr_i16[0] == 0
      assert arr_i16[1] == 0xdead'i16
      assert arr_i16[2] == 0xbeef'i16
      assert arr_i16[3] == 0

      var arr_u16: array[4, uint16]
      fs.setPosition(0)
      fs.read(arr_u16, 1, 2)
      assert arr_u16[0] == 0
      assert arr_u16[1] == 0xdead'u16
      assert arr_u16[2] == 0xbeef'u16
      assert arr_u16[3] == 0

      var arr_i32: array[4, int32]
      fs.setPosition(0)
      fs.read(arr_i32, 1, 2)
      assert arr_i32[0] == 0
      assert arr_i32[1] == 0xdeadbeef'i32
      assert arr_i32[2] == 0xcafebabe'i32
      assert arr_i32[3] == 0

      var arr_u32: array[4, uint32]
      fs.setPosition(0)
      fs.read(arr_u32, 1, 2)
      assert arr_u32[0] == 0
      assert arr_u32[1] == 0xdeadbeef'u32
      assert arr_u32[2] == 0xcafebabe'u32
      assert arr_u32[3] == 0

      var arr_i64: array[4, int64]
      fs.setPosition(0)
      fs.read(arr_i64, 1, 2)
      assert arr_i64[0] == 0
      assert arr_i64[1] == 0xdeadbeefcafebabe'i64
      assert arr_i64[2] == 0xfeedface0d15ea5e'i64
      assert arr_i64[3] == 0

      var arr_u64: array[4, uint64]
      fs.setPosition(0)
      fs.read(arr_u64, 1, 2)
      assert arr_u64[0] == 0
      assert arr_u64[1] == 0xdeadbeefcafebabe'u64
      assert arr_u64[2] == 0xfeedface0d15ea5e'u64
      assert arr_u64[3] == 0

      var arr_f32: array[3, float32]
      fs.read(arr_f32, 1, 1)
      assert arr_f32[0] == 0
      assert arr_f32[1] == TestFloat32
      assert arr_f32[2] == 0

      var arr_f64: array[3, float64]
      fs.read(arr_f64, 1, 1)
      assert arr_f64[0] == 0
      assert arr_f64[1] == TestFloat64
      assert arr_f64[2] == 0

      assert fs.getPosition() == 28
      fs.close()

      proc readBufTest(numValues: Natural) =
        var fs = newFileStream(TestFileBigBE, bigEndian)
        var buf: array[ReadChunkSize*3, uint64]
        let offs = 123

        fs.read(buf, offs, numValues)

        for i in 0..<offs:
          assert buf[i] == 0
        for i in 0..<numValues:
          assert buf[offs + i] == MagicValue64_1 + i.uint64
        for i in offs+numValues..buf.high:
          assert buf[i] == 0
        fs.close()

      readBufTest(0)
      readBufTest(10)
      readBufTest(ReadChunkSize)
      readBufTest(ReadChunkSize * 2)
      readBufTest(ReadChunkSize + 10)

    # }}}
    block: # {{{ peek/openArray
      var fs = newFileStream(TestFileBE, bigEndian)

      var arr_i8: array[4, int8]
      fs.peek(arr_i8, 1, 2)
      assert arr_i8[0] == 0
      assert arr_i8[1] == 0xde'i8
      assert arr_i8[2] == 0xad'i8
      assert arr_i8[3] == 0

      var arr_u8: array[4, uint8]
      fs.peek(arr_u8, 1, 2)
      assert arr_u8[0] == 0
      assert arr_u8[1] == 0xde'u8
      assert arr_u8[2] == 0xad'u8
      assert arr_u8[3] == 0

      var arr_i16: array[4, int16]
      fs.peek(arr_i16, 1, 2)
      assert arr_i16[0] == 0
      assert arr_i16[1] == 0xdead'i16
      assert arr_i16[2] == 0xbeef'i16
      assert arr_i16[3] == 0

      var arr_u16: array[4, uint16]
      fs.peek(arr_u16, 1, 2)
      assert arr_u16[0] == 0
      assert arr_u16[1] == 0xdead'u16
      assert arr_u16[2] == 0xbeef'u16
      assert arr_u16[3] == 0

      var arr_i32: array[4, int32]
      fs.peek(arr_i32, 1, 2)
      assert arr_i32[0] == 0
      assert arr_i32[1] == 0xdeadbeef'i32
      assert arr_i32[2] == 0xcafebabe'i32
      assert arr_i32[3] == 0

      var arr_u32: array[4, uint32]
      fs.peek(arr_u32, 1, 2)
      assert arr_u32[0] == 0
      assert arr_u32[1] == 0xdeadbeef'u32
      assert arr_u32[2] == 0xcafebabe'u32
      assert arr_u32[3] == 0

      var arr_i64: array[4, int64]
      fs.peek(arr_i64, 1, 2)
      assert arr_i64[0] == 0
      assert arr_i64[1] == 0xdeadbeefcafebabe'i64
      assert arr_i64[2] == 0xfeedface0d15ea5e'i64
      assert arr_i64[3] == 0

      var arr_u64: array[4, uint64]
      fs.peek(arr_u64, 1, 2)
      assert arr_u64[0] == 0
      assert arr_u64[1] == 0xdeadbeefcafebabe'u64
      assert arr_u64[2] == 0xfeedface0d15ea5e'u64
      assert arr_u64[3] == 0

      assert fs.getPosition() == 0
      fs.setPosition(16)
      var arr_f32: array[3, float32]
      fs.peek(arr_f32, 1, 1)
      assert arr_f32[0] == 0
      assert arr_f32[1] == TestFloat32
      assert arr_f32[2] == 0

      fs.setPosition(20)
      var arr_f64: array[3, float64]
      fs.peek(arr_f64, 1, 1)
      assert arr_f64[0] == 0
      assert arr_f64[1] == TestFloat64
      assert arr_f64[2] == 0

      assert fs.getPosition() == 20
      fs.close()

      proc readBufTest(numValues: Natural) =
        var fs = newFileStream(TestFileBigBE, bigEndian)
        var buf: array[ReadChunkSize*3, uint64]
        let offs = 123

        for n in 0..3:
          fs.peek(buf, offs, numValues)

          for i in 0..<offs:
            assert buf[i] == 0
          for i in 0..<numValues:
            assert buf[offs + i] == MagicValue64_1 + i.uint64
          for i in offs+numValues..buf.high:
            assert buf[i] == 0

        assert fs.getPosition() == 0
        fs.close()

      readBufTest(0)
      readBufTest(10)
      readBufTest(ReadChunkSize)
      readBufTest(ReadChunkSize * 2)
      readBufTest(ReadChunkSize + 10)

    # }}}
  # }}}
  block: # {{{ Little endian

    block: # {{{ read/func
      var fs = newFileStream(TestFileLE, littleEndian)

      assert fs.read(int8)   == 0xbe'i8
      assert fs.read(int8)   == 0xba'i8
      fs.setPosition(0)
      assert fs.read(uint8)  == 0xbe'u8
      assert fs.read(uint8)  == 0xba'u8
      fs.setPosition(0)
      assert fs.read(int16)  == 0xbabe'i16
      assert fs.read(int16)  == 0xcafe'i16
      fs.setPosition(0)
      assert fs.read(uint16) == 0xbabe'u16
      assert fs.read(uint16) == 0xcafe'u16
      fs.setPosition(0)
      assert fs.read(int32)  == 0xcafebabe'i32
      assert fs.read(int32)  == 0xdeadbeef'i32
      fs.setPosition(0)
      assert fs.read(uint32) == 0xcafebabe'u32
      assert fs.read(uint32) == 0xdeadbeef'u32
      fs.setPosition(0)
      assert fs.read(int64)  == 0xdeadbeefcafebabe'i64
      assert fs.read(int64)  == 0xfeedface0d15ea5e'i64
      fs.setPosition(0)
      assert fs.read(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.read(uint64) == 0xfeedface0d15ea5e'u64
      fs.setPosition(0)
      assert fs.read(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.read(uint64) == 0xfeedface0d15ea5e'u64

      assert fs.read(float32) == TestFloat32
      assert fs.read(float64) == TestFloat64
      assert fs.getPosition == 28

      assert fs.readStr(TestString.len) == TestString
      assert fs.readChar() == TestChar
      assert fs.readBool() == true
      assert fs.readBool() == true
      assert fs.readBool() == false
      assert fs.readBool() == true
      assert fs.readBool() == true
      fs.close()

    # }}}
    block: # {{{ peek/func
      var fs = newFileStream(TestFileLE, littleEndian)

      assert fs.peek(int8)   == 0xbe'i8
      assert fs.peek(int8)   == 0xbe'i8
      assert fs.peek(uint8)  == 0xbe'u8
      assert fs.peek(uint8)  == 0xbe'u8
      assert fs.peek(int16)  == 0xbabe'i16
      assert fs.peek(int16)  == 0xbabe'i16
      assert fs.peek(uint16) == 0xbabe'u16
      assert fs.peek(uint16) == 0xbabe'u16
      assert fs.peek(int32)  == 0xcafebabe'i32
      assert fs.peek(int32)  == 0xcafebabe'i32
      assert fs.peek(uint32) == 0xcafebabe'u32
      assert fs.peek(uint32) == 0xcafebabe'u32
      assert fs.peek(int64)  == 0xdeadbeefcafebabe'i64
      assert fs.peek(int64)  == 0xdeadbeefcafebabe'i64
      assert fs.peek(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.peek(uint64) == 0xdeadbeefcafebabe'u64
      assert fs.getPosition() == 0

      fs.setPosition(16)
      assert fs.peek(float32) == TestFloat32
      fs.setPosition(20)
      assert fs.peek(float64) == TestFloat64
      assert fs.getPosition() == 20

      fs.setPosition(28)
      assert fs.peekStr(TestString.len) == TestString
      fs.setPosition(TestString.len, sspCur)
      assert fs.peekChar() == TestChar; fs.setPosition(1, sspCur)
      assert fs.peekBool() == true;     fs.setPosition(1, sspCur)
      assert fs.peekBool() == true;     fs.setPosition(1, sspCur)
      assert fs.peekBool() == false;    fs.setPosition(1, sspCur)
      assert fs.peekBool() == true;     fs.setPosition(1, sspCur)
      assert fs.peekBool() == true
      fs.close()

    # }}}
    block: # {{{ read/openArray
      var fs = newFileStream(TestFileLE, littleEndian)
      var arr_i8: array[4, int8]

      fs.read(arr_i8, 1, 2)
      assert arr_i8[0] == 0
      assert arr_i8[1] == 0xbe'i8
      assert arr_i8[2] == 0xba'i8
      assert arr_i8[3] == 0

      var arr_u8: array[4, uint8]
      fs.setPosition(0)
      fs.read(arr_u8, 1, 2)
      assert arr_u8[0] == 0
      assert arr_u8[1] == 0xbe'u8
      assert arr_u8[2] == 0xba'u8
      assert arr_u8[3] == 0

      var arr_i16: array[4, int16]
      fs.setPosition(0)
      fs.read(arr_i16, 1, 2)
      assert arr_i16[0] == 0
      assert arr_i16[1] == 0xbabe'i16
      assert arr_i16[2] == 0xcafe'i16
      assert arr_i16[3] == 0

      var arr_u16: array[4, uint16]
      fs.setPosition(0)
      fs.read(arr_u16, 1, 2)
      assert arr_u16[0] == 0
      assert arr_u16[1] == 0xbabe'u16
      assert arr_u16[2] == 0xcafe'u16
      assert arr_u16[3] == 0

      var arr_i32: array[4, int32]
      fs.setPosition(0)
      fs.read(arr_i32, 1, 2)
      assert arr_i32[0] == 0
      assert arr_i32[1] == 0xcafebabe'i32
      assert arr_i32[2] == 0xdeadbeef'i32
      assert arr_i32[3] == 0

      var arr_u32: array[4, uint32]
      fs.setPosition(0)
      fs.read(arr_u32, 1, 2)
      assert arr_u32[0] == 0
      assert arr_u32[1] == 0xcafebabe'u32
      assert arr_u32[2] == 0xdeadbeef'u32
      assert arr_u32[3] == 0

      var arr_i64: array[4, int64]
      fs.setPosition(0)
      fs.read(arr_i64, 1, 2)
      assert arr_i64[0] == 0
      assert arr_i64[1] == 0xdeadbeefcafebabe'i64
      assert arr_i64[2] == 0xfeedface0d15ea5e'i64
      assert arr_i64[3] == 0

      var arr_u64: array[4, uint64]
      fs.setPosition(0)
      fs.read(arr_u64, 1, 2)
      assert arr_u64[0] == 0
      assert arr_u64[1] == 0xdeadbeefcafebabe'u64
      assert arr_u64[2] == 0xfeedface0d15ea5e'u64
      assert arr_u64[3] == 0

      var arr_f32: array[3, float32]
      fs.read(arr_f32, 1, 1)
      assert arr_f32[0] == 0
      assert arr_f32[1] == TestFloat32
      assert arr_f32[2] == 0

      var arr_f64: array[3, float64]
      fs.read(arr_f64, 1, 1)
      assert arr_f64[0] == 0
      assert arr_f64[1] == TestFloat64
      assert arr_f64[2] == 0

      assert fs.getPosition() == 28

      fs.close()

    # }}}
    block: # {{{ peek/openArray
      var fs = newFileStream(TestFileLE, littleEndian)

      var arr_i8: array[4, int8]
      fs.peek(arr_i8, 1, 2)
      assert arr_i8[0] == 0
      assert arr_i8[1] == 0xbe'i8
      assert arr_i8[2] == 0xba'i8
      assert arr_i8[3] == 0

      var arr_u8: array[4, uint8]
      fs.peek(arr_u8, 1, 2)
      assert arr_u8[0] == 0
      assert arr_u8[1] == 0xbe'u8
      assert arr_u8[2] == 0xba'u8
      assert arr_u8[3] == 0

      var arr_i16: array[4, int16]
      fs.peek(arr_i16, 1, 2)
      assert arr_i16[0] == 0
      assert arr_i16[1] == 0xbabe'i16
      assert arr_i16[2] == 0xcafe'i16
      assert arr_i16[3] == 0

      var arr_u16: array[4, uint16]
      fs.peek(arr_u16, 1, 2)
      assert arr_u16[0] == 0
      assert arr_u16[1] == 0xbabe'u16
      assert arr_u16[2] == 0xcafe'u16
      assert arr_u16[3] == 0

      var arr_i32: array[4, int32]
      fs.peek(arr_i32, 1, 2)
      assert arr_i32[0] == 0
      assert arr_i32[1] == 0xcafebabe'i32
      assert arr_i32[2] == 0xdeadbeef'i32
      assert arr_i32[3] == 0

      var arr_u32: array[4, uint32]
      fs.peek(arr_u32, 1, 2)
      assert arr_u32[0] == 0
      assert arr_u32[1] == 0xcafebabe'u32
      assert arr_u32[2] == 0xdeadbeef'u32
      assert arr_u32[3] == 0

      var arr_i64: array[4, int64]
      fs.peek(arr_i64, 1, 2)
      assert arr_i64[0] == 0
      assert arr_i64[1] == 0xdeadbeefcafebabe'i64
      assert arr_i64[2] == 0xfeedface0d15ea5e'i64
      assert arr_i64[3] == 0

      var arr_u64: array[4, uint64]
      fs.peek(arr_u64, 1, 2)
      assert arr_u64[0] == 0
      assert arr_u64[1] == 0xdeadbeefcafebabe'u64
      assert arr_u64[2] == 0xfeedface0d15ea5e'u64
      assert arr_u64[3] == 0

      assert fs.getPosition() == 0
      fs.setPosition(16)
      var arr_f32: array[3, float32]
      fs.peek(arr_f32, 1, 1)
      assert arr_f32[0] == 0
      assert arr_f32[1] == TestFloat32
      assert arr_f32[2] == 0

      fs.setPosition(20)
      var arr_f64: array[3, float64]
      fs.peek(arr_f64, 1, 1)
      assert arr_f64[0] == 0
      assert arr_f64[1] == TestFloat64
      assert arr_f64[2] == 0

      assert fs.getPosition() == 20

      fs.close()

    # }}}
  # }}}
  # }}}
  # {{{ FileStream write tests
  # -------------------------
  block: # {{{ Big endian

    block: # {{{ write/func
      var fs = newFileStream(TestFileBE, bigEndian, fmWrite)
      fs.write(0xde'i8)
      fs.write(0xad'u8)
      fs.write(0xdead'i16)
      fs.write(0xbeef'u16)
      fs.write(0xdeadbeef'i32)
      fs.write(0xcafebabe'u32)
      fs.write(0xdeadbeefcafebabe'i64)
      fs.write(0xfeedface0d15ea5e'u64)
      fs.write(TestFloat32)
      fs.write(TestFloat64)
      fs.writeStr(TestString)
      fs.writeChar(TestChar)
      fs.writeBool(true)
      fs.writeBool(false)
      fs.close()

      fs = newFileStream(TestFileBE, bigEndian)
      assert fs.read(int8)    == 0xde'i8
      assert fs.read(uint8)   == 0xad'u8
      assert fs.read(int16)   == 0xdead'i16
      assert fs.read(uint16)  == 0xbeef'u16
      assert fs.read(int32)   == 0xdeadbeef'i32
      assert fs.read(uint32)  == 0xcafebabe'u32
      assert fs.read(int64)   == 0xdeadbeefcafebabe'i64
      assert fs.read(uint64)  == 0xfeedface0d15ea5e'u64
      assert fs.read(float32) == TestFloat32
      assert fs.read(float64) == TestFloat64
      assert fs.readStr(TestString.len) == TestString
      assert fs.readChar() == TestChar
      assert fs.readBool() == true
      assert fs.readBool() == false
      fs.close()

    # }}}
    block: # {{{ write/openArray
      var buf: array[WriteBufSize*3, uint64]
      for i in 0..buf.high:
        buf[i] = MagicValue64_1 + i.uint64

      proc writeBufTest(numValues: Natural) =
        const offs = 123
        var fs = newFileStream(TestFile, bigEndian, fmWrite)
        fs.write(buf, offs, numValues)
        fs.close()

        var readBuf: array[WriteBufSize*3, uint64]
        fs = newFileStream(TestFile, bigEndian)
        fs.read(readBuf, offs, numValues)
        fs.close()

        for i in 0..<numValues:
          assert readBuf[offs + i] == buf[offs + i]

      writeBufTest(0)
      writeBufTest(10)
      writeBufTest(WriteBufSize)
      writeBufTest(WriteBufSize * 2)
      writeBufTest(WriteBufSize + 10)

    # }}}
  # }}}
  block: # {{{ Little endian

    block: # {{{ write/func
      var fs = newFileStream(TestFileLE, bigEndian, fmWrite)
      fs.write(0xde'i8)
      fs.write(0xad'u8)
      fs.write(0xdead'i16)
      fs.write(0xbeef'u16)
      fs.write(0xdeadbeef'i32)
      fs.write(0xcafebabe'u32)
      fs.write(0xdeadbeefcafebabe'i64)
      fs.write(0xfeedface0d15ea5e'u64)
      fs.write(TestFloat32)
      fs.write(TestFloat64)
      fs.writeStr(TestString)
      fs.writeChar(TestChar)
      fs.writeBool(true)
      fs.writeBool(false)
      fs.close()

      fs = newFileStream(TestFileLE, bigEndian)
      assert fs.read(int8)    == 0xde'i8
      assert fs.read(uint8)   == 0xad'u8
      assert fs.read(int16)   == 0xdead'i16
      assert fs.read(uint16)  == 0xbeef'u16
      assert fs.read(int32)   == 0xdeadbeef'i32
      assert fs.read(uint32)  == 0xcafebabe'u32
      assert fs.read(int64)   == 0xdeadbeefcafebabe'i64
      assert fs.read(uint64)  == 0xfeedface0d15ea5e'u64
      assert fs.read(float32) == TestFloat32
      assert fs.read(float64) == TestFloat64
      assert fs.readStr(TestString.len) == TestString
      assert fs.readChar() == TestChar
      assert fs.readBool() == true
      assert fs.readBool() == false
      fs.close()

    # }}}
    block: # {{{ write/openArray
      var buf: array[WriteBufSize*3, uint64]
      for i in 0..buf.high:
        buf[i] = MagicValue64_1 + i.uint64

      proc writeBufTest(numValues: Natural) =
        const offs = 123
        var fs = newFileStream(TestFile, littleEndian, fmWrite)
        fs.write(buf, offs, numValues)
        fs.close()

        var readBuf: array[WriteBufSize*3, uint64]
        fs = newFileStream(TestFile, littleEndian)
        fs.read(readBuf, offs, numValues)
        fs.close()

        for i in 0..<numValues:
          assert readBuf[offs + i] == buf[offs + i]

      writeBufTest(0)
      writeBufTest(10)
      writeBufTest(WriteBufSize)
      writeBufTest(WriteBufSize * 2)
      writeBufTest(WriteBufSize + 10)

    # }}}
  # }}}
  block: # {{{ Mixed endian

    var fs = newFileStream(TestFileLE, bigEndian, fmWrite)
    fs.write(0xde'i8)
    fs.write(0xad'u8)
    fs.write(0xdead'i16)
    fs.write(0xbeef'u16)

    fs.endian = littleEndian
    fs.write(0xdeadbeef'i32)
    fs.write(0xcafebabe'u32)
    fs.write(0xdeadbeefcafebabe'i64)
    fs.write(0xfeedface0d15ea5e'u64)

    fs.endian = bigEndian
    fs.write(TestFloat32)
    fs.write(TestFloat64)
    fs.writeStr(TestString)
    fs.writeChar(TestChar)
    fs.writeBool(true)
    fs.writeBool(false)
    fs.close()

    fs = newFileStream(TestFileLE, bigEndian)
    assert fs.read(int8)    == 0xde'i8
    assert fs.read(uint8)   == 0xad'u8
    assert fs.read(int16)   == 0xdead'i16
    assert fs.read(uint16)  == 0xbeef'u16

    fs.endian = littleEndian
    assert fs.read(int32)   == 0xdeadbeef'i32
    assert fs.read(uint32)  == 0xcafebabe'u32
    assert fs.read(int64)   == 0xdeadbeefcafebabe'i64
    assert fs.read(uint64)  == 0xfeedface0d15ea5e'u64

    fs.endian = bigEndian
    assert fs.read(float32) == TestFloat32
    assert fs.read(float64) == TestFloat64
    assert fs.readStr(TestString.len) == TestString
    assert fs.readChar() == TestChar
    assert fs.readBool() == true
    assert fs.readBool() == false
    fs.close()

  # }}}
  # }}}

  # {{{ Test byte buffer creation
  var
    testByteBufBE: seq[byte]
    testByteBufLE: seq[byte]
    testByteBufBigBE: seq[byte]
    testByteBufBigLE: seq[byte]

  block:
    proc addSeq(s: var seq[byte], buf: openArray[byte]) =
      for v in buf:
        s.add(v)

    testByteBufBE.add(cast[array[8, byte]](toBE(MagicValue64_1)))
    testByteBufBE.add(cast[array[8, byte]](toBE(MagicValue64_2)))
    testByteBufBE.add(cast[array[4, byte]](toBE(TestFloat32)))
    testByteBufBE.add(cast[array[8, byte]](toBE(TestFloat64)))
    testByteBufBE.add(cast[array[TestString.len, byte]](TestString))
    testByteBufBE.add(cast[array[1, byte]](TestChar))
    testByteBufBE.add(cast[seq[byte]](TestBooleans))
#[
  block:
    var outf = open(TestFileLE, fmWrite)
    var buf: array[2, uint64]
    buf[0] = toLE(MagicValue64_1)
    buf[1] = toLE(MagicValue64_2)
    discard writeBuffer(outf, buf[0].addr, 16)

    var f32 = toLE(TestFloat32)
    discard writeBuffer(outf, f32.addr, 4)
    var f64 = toLE(TestFloat64)
    discard writeBuffer(outf, f64.addr, 8)

    discard writeBuffer(outf, TestString[0].unsafeAddr, TestString.len)
    discard writeBuffer(outf, TestChar.unsafeAddr, 1)
    discard writeBytes(outf, TestBooleans, 0, TestBooleans.len)
    close(outf)

  block:
    var outf = open(TestFileBigBE, fmWrite)
    var u64: uint64
    for i in 0..<ReadChunkSize*3:
      u64 = toBE(MagicValue64_1 + i.uint64)
      discard writeBuffer(outf, u64.addr, 8)
    close(outf)

  block:
    var outf = open(TestFileBigLE, fmWrite)
    var u64: uint64
    for i in 0..<ReadChunkSize*3:
      u64 = toLE(MagicValue64_1 + i.uint64)
      discard writeBuffer(outf, u64.addr, 8)
    close(outf)
]#
  # }}}

# vim: et:ts=2:sw=2:fdm=marker
