import { KoreaderCreateRequestDto } from './koreader-requests.dto';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  ValidateNested,
  Matches,
  IsUrl,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';

export class KoreaderDiscoveryQueryDto {
  @IsString()
  @MinLength(2)
  @MaxLength(200)
  q!: string;

  @IsOptional()
  @IsIn(['en', 'fr', 'es', 'de', 'it', 'pt'])
  language?: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  genre?: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  refine?: string;

  @IsOptional()
  @IsIn(['popular', 'new'])
  sort?: 'popular' | 'new';

  @IsOptional()
  @IsIn(['all', 'title', 'author', 'series', 'isbn'])
  field: 'all' | 'title' | 'author' | 'series' | 'isbn' = 'all';

  @IsOptional()
  @IsIn(['all', 'library', 'requestable'])
  scope: 'all' | 'library' | 'requestable' = 'all';

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1000)
  page = 1;
}

export class KoreaderBrowseQueryDto extends KoreaderDiscoveryQueryDto {
  @IsOptional()
  @IsIn(['popular', 'new'])
  sort: 'popular' | 'new' = 'popular';
  @IsOptional()
  @IsIn(['author', 'subject', 'series'])
  mode: 'author' | 'subject' | 'series' = 'subject';

  @IsOptional()
  @IsString()
  @MaxLength(200)
  author?: string;
}

export class KoreaderWorkParamsDto {
  @IsString()
  @Matches(/^OL[1-9][0-9]*W$/)
  id!: string;
}

export class KoreaderBulkRequestsDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => KoreaderCreateRequestDto)
  books!: KoreaderCreateRequestDto[];
}

export class KoreaderCoverQueryDto {
  @IsString()
  @MaxLength(2048)
  @IsUrl({ protocols: ['https'], require_protocol: true })
  url!: string;
}
