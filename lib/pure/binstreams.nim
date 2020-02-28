import endians
import strutils # TODO for debugging


proc newIOError(msg: string): ref IOError =
  new(result)
  result.msg = msg

proc newIndexError(msg: string): ref IndexError =
  new(result)
  result.msg = msg


when not defined(js):
  type
    FileStream* = ref object
      f: File
      endian: Endianness

    MixedEndianFileStream* = ref object
      f: File

  using fs: MixedEndianFileStream | FileStream

  # {{{ File stream

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

  proc openFileStream*(filename: string, endian: Endianness,
                       mode: FileMode = fmRead,
                       bufSize: int = -1): FileStream =
    var f: File
    if open(f, filename, mode, bufSize):
      return newFileStream(f, endian)
    else:
      raise newIOError("cannot open file")


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
        raise newIOError("cannot read from stream")
      dec(valuesLeft, valuesRead)

      for i in bufIndex..<bufIndex + valuesRead:
        buf[i] = swapEndian(buf[i])
#        TODO
#        swapEndian(buf[i])
      inc(bufIndex, valuesRead)


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
#        TODO
#        writeBuf[i] = buf[bufIndex]
#         swapEndian(writeBuf[i])
        inc(bufIndex)

      let
        bytesToWrite = valuesToWrite * sizeof(T)
        bytesWritten = writeBuffer(fs.f, writeBuf[0].addr, bytesToWrite)

      if bytesWritten != bytesToWrite:
        raise newIOError("cannot write to stream")
      dec(valuesLeft, valuesToWrite)


  proc close*(fs) =
    if fs.f != nil: close(fs.f)
    fs.f = nil

  proc flush*(fs) = flushFile(fs.f)

  proc atEnd*(fs): bool = endOfFile(fs.f)

  proc setPosition*(fs; pos: int, relativeTo: FileSeekPos = fspSet) =
    setFilePos(fs.f, pos, relativeTo)

  proc getPosition*(fs): int = int(getFilePos(fs.f))

  proc read*[T: SomeNumber](fs: FileStream, buf: var openArray[T],
                            startIndex, numValues: Natural) =
    if system.cpuEndian == fs.endian:
      assert startIndex + numValues <= buf.len
      let
        bytesToRead = numValues * sizeof(T)
        bytesRead = readBuffer(fs.f, buf[startIndex].addr, bytesToRead)
      if bytesRead != bytesToRead:
        raise newIOError("cannot read from stream")
    else:
      fs.readAndSwap(buf, startIndex, numValues)

  proc read*(fs: FileStream, T: typedesc[SomeNumber]): T =
    var buf {.noinit.}: array[1, T]
    fs.read(buf, 0, 1)
    result = buf[0]

  proc peek*(fs: FileStream, T: typedesc[SomeNumber]): T =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    fs.read(T)

  proc peek*[T: SomeNumber](fs: FileStream, buf: var openArray[T],
                            startIndex, numValues: Natural) =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    fs.read(buf, startIndex, numValues)

  proc write*[T: SomeNumber](fs: FileStream, buf: openArray[T],
                             startIndex, numValues: Natural) =
    if system.cpuEndian == fs.endian:
      assert startIndex + numValues <= buf.len
      let
        bytesToWrite = numValues * sizeof(T)
        bytesWritten = writeBuffer(fs.f, buf[startIndex].unsafeAddr,
                                   bytesToWrite)
      if bytesWritten != bytesToWrite:
        raise newIOError("cannot write to stream")
    else:
      fs.swapAndWrite(buf, startIndex, numValues)

  proc write*[T: SomeNumber](fs: FileStream, value: T) =
    var buf {.noinit.}: array[1, T]
    buf[0] = value
    fs.write(buf, 0, 1)


  # TODO char, string
  # TODO openarray variants

  # }}}
  # {{{ Mixed file stream
  #
  proc newMixedEndianFileStream*(f: File): MixedEndianFileStream =
    new(result)
    result.f = f

  proc newMixedEndianFileStream*(filename: string, mode: FileMode = fmRead,
                                 bufSize: int = -1): MixedEndianFileStream =
    var f: File
    if open(f, filename, mode, bufSize): result = newMixedEndianFileStream(f)

  proc openMixedEndianFileStream*(filename: string, mode: FileMode = fmRead,
                                  bufSize: int = -1): MixedEndianFileStream =
    var f: File
    if open(f, filename, mode, bufSize):
      return newMixedEndianFileStream(f)
    else:
      raise newIOError("cannot open file")

  # Read

  proc readBE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.read(T, bigEndian, result.addr, 1)

  proc readBE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.readOpenArray(buf, startIndex, numValues, bigEndian)


  proc readLE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.read(T, littleEndian, result.addr, 1)

  proc readLE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.readOpenArray(buf, startIndex, numValues, littleEndian)


  proc read(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
            srcEndian: Endianness): T =
    fs.read(T, srcEndian, result.addr, 1)

  proc read*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                            startIndex, numValues: Natural,
                            srcEndian: Endianness): T =
    fs.readOpenArray(buf, startIndex, numValues, srcEndian)


  # Peek

  proc peekBE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.peek(T, bigEndian, result.addr, 1)

  proc peekBE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.peekOpenArray(buf, startIndex, numValues, bigEndian)


  proc peekLE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.peek(T, littleEndian, result.addr, 1)

  proc peekLE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.peekOpenArray(buf, startIndex, numValues, littleEndian)


  proc peek(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
            srcEndian: Endianness): T =
    fs.peek(T, srcEndian, result.addr, 1)

  # }}}


# TODO
type
  MixedEndianMemStream* = ref object

  MemStream* = ref object
    endian: Endianness


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

  # {{{ Test data file creation
  block:
    var outf = open(TestFileBE, fmWrite)
    var buf: array[2, uint64]
    when system.cpuEndian == bigEndian:
      buf[0] = MagicValue64_1
      buf[1] = MagicValue64_2
    else:
      buf[0] = swapEndian(MagicValue64_1)
      buf[1] = swapEndian(MagicValue64_2)

    discard writeBuffer(outf, buf[0].addr, 16)

    var f32 = if system.cpuEndian == bigEndian: TestFloat32
              else: swapEndian(TestFloat32)
    discard writeBuffer(outf, f32.addr, 4)

    var f64 = if system.cpuEndian == bigEndian: TestFloat64
              else: swapEndian(TestFloat64)
    discard writeBuffer(outf, f64.addr, 8)
    close(outf)

  block:
    var outf = open(TestFileLE, fmWrite)
    var buf: array[2, uint64]
    when system.cpuEndian == littleEndian:
      buf[0] = MagicValue64_1
      buf[1] = MagicValue64_2
    else:
      buf[0] = swapEndian(MagicValue64_1)
      buf[1] = swapEndian(MagicValue64_2)

    discard writeBuffer(outf, buf[0].addr, 16)

    var f32 = if system.cpuEndian == littleEndian: TestFloat32
              else: swapEndian(TestFloat32)
    discard writeBuffer(outf, f32.addr, 4)

    var f64 = if system.cpuEndian == littleEndian: TestFloat64
              else: swapEndian(TestFloat64)
    discard writeBuffer(outf, f64.addr, 8)
    close(outf)

  block:
    var outf = open(TestFileBigBE, fmWrite)
    var u64: uint64
    for i in 0..511:
      u64 = if system.cpuEndian == bigEndian: MagicValue64_1 + i.uint64
            else: swapEndian(MagicValue64_1 + i.uint64)
      discard writeBuffer(outf, u64.addr, 8)
    close(outf)

  block:
    var outf = open(TestFileBigLE, fmWrite)
    var u64: uint64
    for i in 0..511:
      u64 = if system.cpuEndian == littleEndian: MagicValue64_1 + i.uint64
            else: swapEndian(MagicValue64_1 + i.uint64)
      discard writeBuffer(outf, u64.addr, 8)
    close(outf)

  # }}}

  # Helpers
  template getAs(T: typedesc[SomeNumber], buf: openArray[byte],
                 startIndex: Natural): T =
    cast[ptr T](buf[startIndex].addr)[]

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
        var buf: array[1024, uint64]
        let offs = 123

        fs.read(buf, offs, numValues)

        for i in 0..<offs:
          assert buf[i] == 0
        for i in 0..<numValues:
          assert buf[offs + i] == MagicValue64_1 + i.uint64
        for i in offs+numValues..buf.high:
          assert buf[i] == 0
        fs.close()

      readBufTest(0)    # should do nothing
      readBufTest(100)  # less than one full internal buffer worth of data
      readBufTest(128)  # 128*8 = 1024, internal buffer size
      readBufTest(256)  # 128*8 = 2024, internal buffer size * 2
      readBufTest(300)  # bit more than 2 full internal buffer worth of data

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
        var buf: array[1024, uint64]
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

      readBufTest(0)    # should do nothing
      readBufTest(100)  # less than one full internal buffer worth of data
      readBufTest(128)  # 128*8 = 1024, internal buffer size
      readBufTest(256)  # 128*8 = 2024, internal buffer size * 2
      readBufTest(300)  # bit more than 2 full internal buffer worth of data

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
  # }}}

  # ------------------------------------
  # MixedEndianFileStream Read tests
  # ------------------------------------

# vim: et:ts=2:sw=2:fdm=marker
