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

  # {{{ File stream

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


  # Internal implementation

  using fs: MixedEndianFileStream | FileStream

  proc readAndSwap(fs; T: typedesc[SomeNumber],
                   buf: pointer, numValues: Natural) =
    const ReadBufSize = 1024
    var
      readBuf {.noinit.}: array[ReadBufSize, byte]
      readArr = cast[ptr UncheckedArray[T]](readBuf[0].addr)
      readArrMaxValues = ReadBufSize div sizeof(T)
      destArr = cast[ptr UncheckedArray[T]](buf)
      destPos = 0
      valuesLeft = numValues

    while valuesLeft > 0:
      let
        valuesToRead = min(valuesLeft, readArrMaxValues)
        bytesToRead = valuesToRead * sizeof(T)
        bytesRead = readBytes(fs.f, readBuf, 0, bytesToRead)

      if bytesRead != bytesToRead:
        raise newIOError("cannot read from stream")
      dec(valuesLeft, valuesToRead)

      for i in 0..<valuesToRead:
        destArr[destPos] = swapEndian(readArr[i])
        inc(destPos)

  proc read(fs; T: typedesc[SomeNumber], srcEndian: Endianness,
            buf: pointer, numValues: Natural) =
    if system.cpuEndian == srcEndian:
      let bytesToRead = numValues * sizeof(T)
      if readBuffer(fs.f, buf, bytesToRead) != bytesToRead:
        raise newIOError("cannot read from stream")
    else:
      readAndSwap(fs, T, buf, numValues)

  proc peek(fs; T: typedesc[SomeNumber], srcEndian: Endianness,
            buf: pointer, numValues: Natural) =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    read(fs, T, srcEndian, buf, numValues)

  proc readOpenArray[T: SomeNumber](fs; buf: var openArray[T],
                                    startIndex, numValues: Natural,
                                    srcEndian: Endianness) =
    assert startIndex < buf.len
    assert startIndex + numValues <= buf.len
    fs.read(T, srcEndian, buf[startIndex].addr, numValues)

  proc peekOpenArray[T: SomeNumber](fs; buf: var openArray[T],
                                    startIndex, numValues: Natural,
                                    srcEndian: Endianness) =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    fs.readOpenArray(buf, startIndex, numValues, srcEndian)


  proc swapAndWrite(fs; T: typedesc[SomeNumber],
                    buf: pointer, numValues: Natural) =
    const WriteBufSize = 1024
    var
      writeBuf {.noinit.}: array[WriteBufSize, byte]
      writeArr = cast[ptr UncheckedArray[T]](writeBuf[0].addr)
      writeArrMaxValues = WriteBufSize div sizeof(T)
      srcArr = cast[ptr UncheckedArray[T]](buf)
      srcPos = 0
      valuesLeft = numValues

    while valuesLeft > 0:
      let valuesToWrite = min(valuesLeft, writeArrMaxValues)
      for i in 0..<valuesToWrite:
        writeArr[i] = swapEndian(srcArr[srcPos])
        inc(srcPos)

      let
        bytesToWrite = valuesToWrite * sizeof(T)
        bytesWritten = writeBytes(fs.f, writeBuf, 0, bytesToWrite)

      if bytesWritten != bytesToWrite:
        raise newIOError("cannot write to stream")
      dec(valuesLeft, valuesToWrite)

  proc write(fs; T: typedesc[SomeNumber], destEndian: Endianness,
             buf: pointer, numValues: Natural) =
    if system.cpuEndian == destEndian:
      let bytesToWrite = numValues * sizeof(T)
      if writeBuffer(fs.f, buf, bytesToWrite) != bytesToWrite:
        raise newIOError("cannot write to stream")
    else:
      swapAndWrite(fs, T, buf, numValues)

  proc writeOpenArray[T: SomeNumber](fs; buf: openArray[T],
                                     startIndex, numValues: Natural,
                                     destEndian: Endianness) =
    assert startIndex < buf.len
    assert startIndex + numValues <= buf.len
    fs.write(T, destEndian, buf[startIndex].unsafeAddr, numValues)


  # API

  proc close*(fs) =
    if fs.f != nil: close(fs.f)
    fs.f = nil

  proc flush*(fs) = flushFile(fs.f)

  proc atEnd*(fs): bool = endOfFile(fs.f)

  proc setPosition*(fs; pos: int, relativeTo: FileSeekPos = fspSet) =
    setFilePos(fs.f, pos, relativeTo)

  proc getPosition*(fs): int = int(getFilePos(fs.f))


  proc read*(fs: FileStream, T: typedesc[SomeNumber]): T =
    fs.read(T, fs.endian, result.addr, 1)

  proc read*(fs: FileStream, T: typedesc[SomeNumber],
             buf: pointer, numValues: Natural) =
    fs.read(T, fs.endian, buf, numValues)

  proc read*[T: SomeNumber](fs: FileStream, buf: var openArray[T],
                            startIndex, numValues: Natural) =
    fs.readOpenArray(buf, startIndex, numValues, fs.endian)


  proc peek*(fs: FileStream, T: typedesc[SomeNumber]): T =
    fs.peek(T, fs.endian, result.addr, 1)

  proc peek*(fs: FileStream, T: typedesc[SomeNumber],
             buf: pointer, numValues: Natural) =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    fs.peek(T, fs.endian, buf, numValues)

  proc peek*[T: SomeNumber](fs: FileStream, buf: var openArray[T],
                            startIndex, numValues: Natural) =
    let pos = fs.getPosition()
    defer: fs.setPosition(pos)
    fs.peekOpenArray(buf, startIndex, numValues, fs.endian)


  proc peek*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                            startIndex, numValues: Natural,
                            srcEndian: Endianness): T =
    fs.peekOpenArray(buf, startIndex, numValues, srcEndian)


  proc write*[T: SomeNumber](fs: FileStream, value: T) =
    fs.write(T, fs.endian, value.unsafeAddr, 1)

  proc write*(fs: FileStream, T: typedesc[SomeNumber],
              buf: pointer, numValues: Natural) =
    fs.write(T, fs.endian, buf, numValues)

  proc write*[T: SomeNumber](fs: FileStream, buf: openArray[T],
                             startIndex, numValues: Natural) =
    fs.writeOpenArray(buf, startIndex, numValues, fs.endian)


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

  proc readBE*(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
               buf: pointer, numValues: Natural) =
    fs.read(T, bigEndian, buf, numValues)

  proc readBE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.readOpenArray(buf, startIndex, numValues, bigEndian)


  proc readLE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.read(T, littleEndian, result.addr, 1)

  proc readLE*(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
               buf: pointer, numValues: Natural) =
    fs.read(T, littleEndian, buf, numValues)

  proc readLE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.readOpenArray(buf, startIndex, numValues, littleEndian)


  proc read(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
            srcEndian: Endianness): T =
    fs.read(T, srcEndian, result.addr, 1)

  proc read*(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
             buf: pointer, numValues: Natural, srcEndian: Endianness): T =
    fs.read(T, srcEndian, buf, numValues)

  proc read*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                            startIndex, numValues: Natural,
                            srcEndian: Endianness): T =
    fs.readOpenArray(buf, startIndex, numValues, srcEndian)


  # Peek

  proc peekBE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.peek(T, bigEndian, result.addr, 1)

  proc peekBE*(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
               buf: pointer, numValues: Natural) =
    fs.peek(T, bigEndian, buf, numValues)

  proc peekBE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.peekOpenArray(buf, startIndex, numValues, bigEndian)


  proc peekLE(fs: MixedEndianFileStream, T: typedesc[SomeNumber]): T =
    fs.peek(T, littleEndian, result.addr, 1)

  proc peekLE*(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
               buf: pointer, numValues: Natural) =
    fs.peek(T, littleEndian, buf, numValues)

  proc peekLE*[T: SomeNumber](fs: MixedEndianFileStream, buf: var openArray[T],
                              startIndex, numValues: Natural) =
    fs.peekOpenArray(buf, startIndex, numValues, littleEndian)


  proc peek(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
            srcEndian: Endianness): T =
    fs.peek(T, srcEndian, result.addr, 1)

  proc peek*(fs: MixedEndianFileStream, T: typedesc[SomeNumber],
             buf: pointer, numValues: Natural, srcEndian: Endianness): T =
    fs.peek(T, srcEndian, buf, numValues)

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

  const
    TestFloat64 = 123456789.123456'f64
    TestFloat32 = 1234.1234'f32
    MagicValue64_1 = 0xdeadbeefcafebabe'u64
    MagicValue64_2 = 0xfeedface0d15ea5e'u64

  # {{{ Test data file creation
  block:
    var outf = open(TestFileBE, fmWrite)
    var buf: array[16, byte]
    toBytesBE(MagicValue64_1, buf, 0)
    toBytesBE(MagicValue64_2, buf, 8)
    discard writeBytes(outf, buf, 0, 16)

    toBytesBE(TestFloat32, buf, 0)
    discard writeBytes(outf, buf, 0, 4)

    toBytesBE(TestFloat64, buf, 0)
    discard writeBytes(outf, buf, 0, 8)
    close(outf)

  block:
    var outf = open(TestFileLE, fmWrite)
    var buf: array[16, byte]
    toBytesLE(MagicValue64_1, buf, 0)
    toBytesLE(MagicValue64_2, buf, 8)
    discard writeBytes(outf, buf, 0, 16)

    toBytesLE(TestFloat32, buf, 0)
    discard writeBytes(outf, buf, 0, 4)

    toBytesLE(TestFloat64, buf, 0)
    discard writeBytes(outf, buf, 0, 8)
    close(outf)

  block:
    var outf = open(TestFileBigBE, fmWrite)
    var buf: array[8, byte]
    for i in 0..511: # write 4k worth of data
      toBytesBE(MagicValue64_1 + i.uint64, buf, 0)
      discard writeBytes(outf, buf, 0, 8)
    close(outf)

  block:
    var outf = open(TestFileBigLE, fmWrite)
    var buf: array[8, byte]
    for i in 0..511: # write 4k worth of data
      toBytesLE(MagicValue64_1 + i.uint64, buf, 0)
      discard writeBytes(outf, buf, 0, 8)
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
      readBufTest(100)  # less 1 internal buffer worth of data
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
      readBufTest(100)  # less 1 internal buffer worth of data
      readBufTest(128)  # 128*8 = 1024, internal buffer size
      readBufTest(256)  # 128*8 = 2024, internal buffer size * 2
      readBufTest(300)  # bit more than 2 full internal buffer worth of data

    # }}}
    block: # {{{ read/pointer
      var fs = newFileStream(TestFileBE, bigEndian)
      var inbuf: array[17, byte]

      fs.read(int8, inbuf[1].addr, 1)
      fs.read(int8, inbuf[2].addr, 1)
      assert getAs(int8, inbuf, 1) == 0xde'i8
      assert getAs(int8, inbuf, 2) == 0xad'i8

      fs.setPosition(0)
      fs.read(uint8, inbuf[1].addr, 1)
      fs.read(uint8, inbuf[2].addr, 1)
      assert getAs(uint8, inbuf, 1) == 0xde'u8
      assert getAs(uint8, inbuf, 2) == 0xad'u8

      fs.setPosition(0)
      fs.read(int16, inbuf[1].addr, 1)
      fs.read(int16, inbuf[3].addr, 1)
      assert getAs(int16, inbuf, 1) == 0xdead'i16
      assert getAs(int16, inbuf, 3) == 0xbeef'i16

      fs.setPosition(0)
      fs.read(uint16, inbuf[1].addr, 1)
      fs.read(uint16, inbuf[3].addr, 1)
      assert getAs(uint16, inbuf, 1) == 0xdead'u16
      assert getAs(uint16, inbuf, 3) == 0xbeef'u16

      fs.setPosition(0)
      fs.read(int32, inbuf[1].addr, 1)
      fs.read(int32, inbuf[5].addr, 1)
      assert getAs(int32, inbuf, 1) == 0xdeadbeef'i32
      assert getAs(int32, inbuf, 5) == 0xcafebabe'i32

      fs.setPosition(0)
      fs.read(uint32, inbuf[1].addr, 1)
      fs.read(uint32, inbuf[5].addr, 1)
      assert getAs(uint32, inbuf, 1) == 0xdeadbeef'u32
      assert getAs(uint32, inbuf, 5) == 0xcafebabe'u32

      fs.setPosition(0)
      fs.read(int64, inbuf[1].addr, 1)
      fs.read(int64, inbuf[9].addr, 1)
      assert getAs(int64, inbuf, 1) == 0xdeadbeefcafebabe'i64
      assert getAs(int64, inbuf, 9) == 0xfeedface0d15ea5e'i64

      fs.setPosition(0)
      fs.read(uint64, inbuf[1].addr, 1)
      fs.read(uint64, inbuf[9].addr, 1)
      assert getAs(uint64, inbuf, 1) == 0xdeadbeefcafebabe'u64
      assert getAs(uint64, inbuf, 9) == 0xfeedface0d15ea5e'u64

      fs.read(float32, inbuf[1].addr, 1)
      fs.read(float64, inbuf[5].addr, 1)
      assert getAs(float32, inbuf, 1) == TestFloat32
      assert getAs(float64, inbuf, 5) == TestFloat64
      assert fs.getPosition() == 28

      fs.close()

      proc readBufTest(numValues: Natural) =
        var fs = newFileStream(TestFileBigLE, littleEndian)
        var buf: array[1024, uint64]
        let offs = 123

        fs.read(uint64, buf[offs].addr, numValues)

        for i in 0..<offs:
          assert buf[i] == 0
        for i in 0..<numValues:
          assert buf[offs + i] == MagicValue64_1 + i.uint64
        for i in offs+numValues..buf.high:
          assert buf[i] == 0
        fs.close()

      readBufTest(0)    # should do nothing
      readBufTest(100)  # less 1 internal buffer worth of data
      readBufTest(128)  # 128*8 = 1024, internal buffer size
      readBufTest(256)  # 128*8 = 2024, internal buffer size * 2
      readBufTest(300)  # bit more than 2 full internal buffer worth of data

    # }}}
    block: # {{{ peek/pointer
      var fs = newFileStream(TestFileBE, bigEndian)
      var inbuf: array[17, byte]

      fs.peek(int8, inbuf[1].addr, 1)
      fs.peek(int8, inbuf[2].addr, 1)
      assert getAs(int8, inbuf, 1) == 0xde'i8
      assert getAs(int8, inbuf, 2) == 0xde'i8

      fs.peek(uint8, inbuf[1].addr, 1)
      fs.peek(uint8, inbuf[2].addr, 1)
      assert getAs(uint8, inbuf, 1) == 0xde'u8
      assert getAs(uint8, inbuf, 2) == 0xde'u8

      fs.peek(int16, inbuf[1].addr, 1)
      fs.peek(int16, inbuf[3].addr, 1)
      assert getAs(int16, inbuf, 1) == 0xdead'i16
      assert getAs(int16, inbuf, 3) == 0xdead'i16

      fs.peek(uint16, inbuf[1].addr, 1)
      fs.peek(uint16, inbuf[3].addr, 1)
      assert getAs(uint16, inbuf, 1) == 0xdead'u16
      assert getAs(uint16, inbuf, 3) == 0xdead'u16

      fs.peek(int32, inbuf[1].addr, 1)
      fs.peek(int32, inbuf[5].addr, 1)
      assert getAs(int32, inbuf, 1) == 0xdeadbeef'i32
      assert getAs(int32, inbuf, 5) == 0xdeadbeef'i32

      fs.peek(uint32, inbuf[1].addr, 1)
      fs.peek(uint32, inbuf[5].addr, 1)
      assert getAs(uint32, inbuf, 1) == 0xdeadbeef'u32
      assert getAs(uint32, inbuf, 5) == 0xdeadbeef'u32

      fs.peek(int64, inbuf[1].addr, 1)
      fs.peek(int64, inbuf[9].addr, 1)
      assert getAs(int64, inbuf, 1) == 0xdeadbeefcafebabe'i64
      assert getAs(int64, inbuf, 9) == 0xdeadbeefcafebabe'i64

      fs.peek(uint64, inbuf[1].addr, 1)
      fs.peek(uint64, inbuf[9].addr, 1)
      assert getAs(uint64, inbuf, 1) == 0xdeadbeefcafebabe'u64
      assert getAs(uint64, inbuf, 9) == 0xdeadbeefcafebabe'u64

      assert fs.getPosition() == 0
      fs.setPosition(16)
      fs.peek(float32, inbuf[1].addr, 1)
      fs.setPosition(20)
      fs.peek(float64, inbuf[5].addr, 1)
      assert getAs(float32, inbuf, 1) == TestFloat32
      assert getAs(float64, inbuf, 5) == TestFloat64
      assert fs.getPosition() == 20

      fs.close()

      proc readBufTest(numValues: Natural) =
        var fs = newFileStream(TestFileBigBE, bigEndian)
        var buf: array[1024, uint64]
        let offs = 123

        for n in 0..3:
          fs.peek(uint64, buf[offs].addr, numValues)

          for i in 0..<offs:
            assert buf[i] == 0
          for i in 0..<numValues:
            assert buf[offs + i] == MagicValue64_1 + i.uint64
          for i in offs+numValues..buf.high:
            assert buf[i] == 0

        assert fs.getPosition() == 0
        fs.close()

      readBufTest(0)    # should do nothing
      readBufTest(100)  # less 1 internal buffer worth of data
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
    block: # {{{ read/pointer
      var fs = newFileStream(TestFileLE, littleEndian)
      var inbuf: array[17, byte]

      fs.read(int8, inbuf[1].addr, 1)
      fs.read(int8, inbuf[2].addr, 1)
      assert getAs(int8, inbuf, 1) == 0xbe'i8
      assert getAs(int8, inbuf, 2) == 0xba'i8

      fs.setPosition(0)
      fs.read(uint8, inbuf[1].addr, 1)
      fs.read(uint8, inbuf[2].addr, 1)
      assert getAs(uint8, inbuf, 1) == 0xbe'u8
      assert getAs(uint8, inbuf, 2) == 0xba'u8

      fs.setPosition(0)
      fs.read(int16, inbuf[1].addr, 1)
      fs.read(int16, inbuf[3].addr, 1)
      assert getAs(int16, inbuf, 1) == 0xbabe'i16
      assert getAs(int16, inbuf, 3) == 0xcafe'i16

      fs.setPosition(0)
      fs.read(uint16, inbuf[1].addr, 1)
      fs.read(uint16, inbuf[3].addr, 1)
      assert getAs(uint16, inbuf, 1) == 0xbabe'u16
      assert getAs(uint16, inbuf, 3) == 0xcafe'u16

      fs.setPosition(0)
      fs.read(int32, inbuf[1].addr, 1)
      fs.read(int32, inbuf[5].addr, 1)
      assert getAs(int32, inbuf, 1) == 0xcafebabe'i32
      assert getAs(int32, inbuf, 5) == 0xdeadbeef'i32

      fs.setPosition(0)
      fs.read(uint32, inbuf[1].addr, 1)
      fs.read(uint32, inbuf[5].addr, 1)
      assert getAs(uint32, inbuf, 1) == 0xcafebabe'u32
      assert getAs(uint32, inbuf, 5) == 0xdeadbeef'u32

      fs.setPosition(0)
      fs.read(int64, inbuf[1].addr, 1)
      fs.read(int64, inbuf[9].addr, 1)
      assert getAs(int64, inbuf, 1) == 0xdeadbeefcafebabe'i64
      assert getAs(int64, inbuf, 9) == 0xfeedface0d15ea5e'i64

      fs.setPosition(0)
      fs.read(uint64, inbuf[1].addr, 1)
      fs.read(uint64, inbuf[9].addr, 1)
      assert getAs(uint64, inbuf, 1) == 0xdeadbeefcafebabe'u64
      assert getAs(uint64, inbuf, 9) == 0xfeedface0d15ea5e'u64

      fs.read(float32, inbuf[1].addr, 1)
      fs.read(float64, inbuf[5].addr, 1)
      assert getAs(float32, inbuf, 1) == TestFloat32
      assert getAs(float64, inbuf, 5) == TestFloat64
      assert fs.getPosition() == 28

      fs.close()
    # }}}
    block: # {{{ peek/pointer
      var fs = newFileStream(TestFileLE, littleEndian)
      var inbuf: array[17, byte]

      fs.peek(int8, inbuf[1].addr, 1)
      fs.peek(int8, inbuf[2].addr, 1)
      assert getAs(int8, inbuf, 1) == 0xbe'i8
      assert getAs(int8, inbuf, 2) == 0xbe'i8

      fs.peek(uint8, inbuf[1].addr, 1)
      fs.peek(uint8, inbuf[2].addr, 1)
      assert getAs(uint8, inbuf, 1) == 0xbe'u8
      assert getAs(uint8, inbuf, 2) == 0xbe'u8

      fs.peek(int16, inbuf[1].addr, 1)
      fs.peek(int16, inbuf[3].addr, 1)
      assert getAs(int16, inbuf, 1) == 0xbabe'i16
      assert getAs(int16, inbuf, 3) == 0xbabe'i16

      fs.peek(uint16, inbuf[1].addr, 1)
      fs.peek(uint16, inbuf[3].addr, 1)
      assert getAs(uint16, inbuf, 1) == 0xbabe'u16
      assert getAs(uint16, inbuf, 3) == 0xbabe'u16

      fs.peek(int32, inbuf[1].addr, 1)
      fs.peek(int32, inbuf[5].addr, 1)
      assert getAs(int32, inbuf, 1) == 0xcafebabe'i32
      assert getAs(int32, inbuf, 5) == 0xcafebabe'i32

      fs.peek(uint32, inbuf[1].addr, 1)
      fs.peek(uint32, inbuf[5].addr, 1)
      assert getAs(uint32, inbuf, 1) == 0xcafebabe'u32
      assert getAs(uint32, inbuf, 5) == 0xcafebabe'u32

      fs.peek(int64, inbuf[1].addr, 1)
      fs.peek(int64, inbuf[9].addr, 1)
      assert getAs(int64, inbuf, 1) == 0xdeadbeefcafebabe'i64
      assert getAs(int64, inbuf, 9) == 0xdeadbeefcafebabe'i64

      fs.peek(uint64, inbuf[1].addr, 1)
      fs.peek(uint64, inbuf[9].addr, 1)
      assert getAs(uint64, inbuf, 1) == 0xdeadbeefcafebabe'u64
      assert getAs(uint64, inbuf, 9) == 0xdeadbeefcafebabe'u64

      assert fs.getPosition() == 0
      fs.setPosition(16)
      fs.peek(float32, inbuf[1].addr, 1)
      fs.setPosition(20)
      fs.peek(float64, inbuf[5].addr, 1)
      assert getAs(float32, inbuf, 1) == TestFloat32
      assert getAs(float64, inbuf, 5) == TestFloat64
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
    # }}}
    block: # {{{ write/pointer
    # }}}
  # }}}
  # }}}

  # ------------------------------------
  # MixedEndianFileStream Read tests
  # ------------------------------------

# vim: et:ts=2:sw=2:fdm=marker
