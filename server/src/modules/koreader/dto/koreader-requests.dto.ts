import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min, MinLength, Matches, IsNumber } from 'class-validator';

export class KoreaderRequestSearchDto {
  @IsString()
  @MinLength(2)
  @MaxLength(200)
  q!: string;

  @IsOptional()
  @IsIn(['title', 'author', 'series', 'isbn'])
  field: 'title' | 'author' | 'series' | 'isbn' = 'title';
}

export class KoreaderRequestPageDto {
  @IsOptional()
  @IsIn(['all', 'pending', 'processing', 'ready', 'failed'])
  filter?: 'all' | 'pending' | 'processing' | 'ready' | 'failed';

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(10000)
  page = 1;
}

// Device requests deliberately cannot choose another user, bypass approval, or supply a release URL.
export class KoreaderCreateRequestDto {
  @IsString()
  @MinLength(1)
  @MaxLength(500)
  title!: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(10)
  @IsString({ each: true })
  @MaxLength(255, { each: true })
  authors?: string[];

  @IsOptional()
  @IsString()
  @MaxLength(500)
  seriesName?: string;

  @IsOptional()
  @IsNumber({ maxDecimalPlaces: 4 })
  @Min(0)
  @Max(9999)
  seriesIndex?: number;

  @IsOptional()
  @IsString()
  @MaxLength(20)
  isbn10?: string;

  @IsOptional()
  @IsString()
  @MaxLength(20)
  isbn13?: string;

  @IsOptional()
  @IsString()
  @MaxLength(20)
  language?: string;

  @IsOptional()
  @IsString()
  @MaxLength(50)
  providerKey?: string;

  @IsOptional()
  @IsString()
  @MaxLength(255)
  providerId?: string;
}

export class KoreaderReleasePageDto extends KoreaderRequestPageDto {
  @IsOptional()
  @IsIn(['true', 'false'])
  refresh = 'false';
}

export class KoreaderGrabReleaseDto {
  @IsString()
  @Matches(/^[a-f0-9]{64}$/)
  releaseId!: string;
}

export class KoreaderReplacementDto {
  @IsString()
  @Matches(/^[a-zA-Z]{2,3}(?:-[a-zA-Z]{2})?$/)
  language!: string;
}

export class KoreaderRequestWatchDto {
  // Up to 50 request ids, comma separated.
  @IsString()
  @Matches(/^\d{1,10}(,\d{1,10}){0,49}$/)
  ids!: string;
}
